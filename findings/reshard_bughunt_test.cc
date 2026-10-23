// Hardware-free reproduction tests for store-owned reshard control-plane bugs
// (R7a, R7b, R8, R2b):
//
//   * R7a (RequestBlockRegistry::Complete, request_block_registry.cc:317-371):
//     LookupAndClaim (:440-491) records multiple concurrent claim_owner tokens
//     in claimed_owners_[key] so pipelined destination stages can share one
//     (req_id, uuid) declaration. However, Complete(req_id, uuid, unit) takes
//     no claim_owner (and CompleteRequestBlocksRequest carries none on the
//     wire) and calls RetireLocked(key) as soon as completed_units_[key].units
//     covers claimed_units_[key] (:358-368), ignoring claimed_owners_[key].
//     When every source rank holds multiple layer pools (e.g. TP ranks each
//     holding fa.l0 and fa.l1) and stage 0's senders finish fa.l0 and vote
//     Complete, RetireLocked wipes request_blocks_, claimed_, claimed_units_,
//     and claimed_owners_ while stage 1 (fa.l1) is still active or before
//     stage 1 has coordinated its transfer.
//
//   * R7b (RequestBlockRegistry::AbandonClaim,
//     request_block_registry.cc:493-509):
//     When the last claim_owner abandons a claim (:503-507), AbandonClaim
//     erases claimed_[key], claimed_units_[key], and claimed_owners_[key]
//     (returning the entry to kRegistered), but does not erase
//     completed_units_[key]. Stale completion votes from before the abandon
//     persist into the next claim and cause premature retirement before all
//     source units of the new claim complete (or immediately inside
//     LookupAndClaim at :476-489).
//
//   * R8 (RequestBlockRegistry::PurgeExpiredRequestBlocksLocked /
//     LookupAndClaim, request_block_registry.cc:61-96, 263, 446-475):
//     Register (:263) sets registration.expires_at = t_reg + ttl_s_ on each
//     request_blocks_[(req_id, unit)] entry, whereas LookupAndClaim (:473) sets
//     claimed_[(req_id, uuid)] = t_claim + ttl_s_ without refreshing
//     registration.expires_at on the claimed request_blocks_ entries. If stage
//     0 claims at t = t_reg + 40s (with ttl_s = 60s), then at t = t_reg + 70s
//     the claim is still live (70 - 40 = 30s <= 60s, so Status reports
//     STATUS_CLAIMED), but PurgeExpiredRequestBlocksLocked (:61-69) erases
//     request_blocks_[(req_id, unit)] and stage 1's LookupAndClaim fails with
//     "Missing producer block registration".
//
//   * R2b (ReshardCoordinator::ExecutePoolReshard,
//     reshard_coordinator.cc:480-544):
//     If receiver arming (SendWorkerRpc for is_sender=false) succeeds at
//     :433-475 but a subsequent sender dispatch (SendWorkerRpc for
//     is_sender=true) fails at :522-544, ExecutePoolReshard returns the sender
//     error without calling registry_->AbandonClaim(req_id, uuid, claim_owner)
//     (unlike the plan-build and receiver-arm failure paths at :422 and :460)
//     and without aborting the armed receiver sessions. The request remains
//     permanently stuck in STATUS_CLAIMED (CancelIfUnclaimed returns false)
//     until TTL expiry.

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/time.h"
#include "tpu_sync/common/control_pipe/control_pipe_client.h"
#include "tpu_sync/common/control_pipe/control_pipe_types.h"
#include "tpu_sync/common/raiden_id.h"
#include "tpu_sync/kv_cache/reshard/declaration_types.h"
#include "tpu_sync/kv_cache/reshard/request_block_registry.h"
#include "tpu_sync/kv_cache/reshard/reshard_service.h"
#include "tpu_sync/kv_cache/reshard/work_unit_directory.h"
#include "tpu_sync/proto/control_pipe.pb.h"
#include "tpu_sync/rpc/controller_service.pb.h"
#include "tpu_sync/rpc/raiden_service.pb.h"

namespace tpu_raiden {
namespace kv_cache {
namespace reshard {
namespace {

using ::absl_testing::StatusIs;
using ::testing::HasSubstr;

RaidenId Unit(int rank) {
  RaidenId id;
  id.job_name = "prefill";
  id.job_replica_id = absl::StrCat(rank);
  id.data_name = "kv_cache";
  id.data_replica_idx = 0;
  return id;
}

RaidenId DstUnit(int idx = 0) {
  RaidenId id;
  id.job_name = "decode";
  id.job_replica_id = absl::StrCat(idx);
  id.data_name = "kv_cache";
  id.data_replica_idx = 0;
  return id;
}

RaidenId PipelineStage(int stage) {
  RaidenId unit = DstUnit();
  unit.job_replica_id = absl::StrCat(unit.job_replica_id, "-rank", stage);
  return unit;
}

tpu_sync::rpc::PoolSpecProto MakePool(const std::string& tag, int64_t live,
                                      int64_t stride, int64_t num_blocks) {
  tpu_sync::rpc::PoolSpecProto pool;
  pool.set_tag(tag);
  pool.set_storage_index(0);
  pool.set_base_offset_bytes(0);
  pool.set_block_stride_bytes(stride);
  pool.set_num_blocks(num_blocks);
  pool.set_dtype_tag("uint8");
  auto* region = pool.add_regions();
  region->set_name("live");
  region->set_offset_bytes(0);
  region->set_stride_bytes(live);
  region->set_unit_bytes(live);
  region->set_num_units(1);
  region->set_units_per_stride(1);
  return pool;
}

class FakeTransport final : public ControlPipeClient {
 public:
  absl::StatusOr<control_pipe::proto::ControlResponseEnvelope> SendRaw(
      absl::string_view endpoint,
      const control_pipe::proto::ControlEnvelope& envelope,
      absl::Duration /*timeout*/) override {
    {
      absl::MutexLock lock(mu_);
      calls_.emplace_back(std::string(endpoint), envelope.payload());
    }
    control_pipe::proto::ControlResponseEnvelope resp_env;
    resp_env.set_request_id(envelope.request_id());
    resp_env.set_status_code(0);
    if (fail_addr_ == endpoint) {
      tpu_sync::rpc::ControlResponse failed;
      failed.set_success(false);
      failed.set_message("injected worker rpc failure");
      resp_env.set_payload(failed.SerializeAsString());
      return resp_env;
    }
    tpu_sync::rpc::ControlResponse ok;
    ok.set_success(true);
    resp_env.set_payload(ok.SerializeAsString());
    return resp_env;
  }

  ControlPipeBackendType backend_type() const override {
    return ControlPipeBackendType::kTcp;
  }

  void FailFor(const std::string& addr) { fail_addr_ = addr; }

  absl::Mutex mu_;
  std::vector<std::pair<std::string, std::string>> calls_;
  std::string fail_addr_;
};

class ReshardBughuntTest : public ::testing::Test {
 protected:
  ReshardBughuntTest() {
    ReshardService::Options options;
    options.port = 0;
    options.client = &transport_;
    options.request_registry_ttl_s = 60.0;
    options.clock = [this]() { return now_; };
    service_ = std::make_unique<ReshardService>(options);
  }

  tpu_sync::rpc::ControlResponse Handle(const std::string& bytes) {
    tpu_sync::rpc::ControlResponse resp;
    resp.ParseFromString(service_->HandleFrame(bytes));
    return resp;
  }

  tpu_sync::rpc::ControllerResponse HandleController(
      const tpu_sync::rpc::ControllerRequest& req) {
    return service_->HandleControllerCommand(req);
  }

  // Registers `num_src` source ranks (each holding layer pools fa.l0..fa.l{S-1})
  // and `num_stages` destination pipeline stages (stage s holds fa.l{s}).
  void RegisterTpPpUnits(int num_src, int num_stages) {
    for (int rank = 0; rank < num_src; ++rank) {
      tpu_sync::rpc::ControlRequest req;
      req.set_command(
          tpu_sync::rpc::ControlRequest::COMMAND_REGISTER_WORK_UNIT);
      auto* reg = req.mutable_register_work_unit_request();
      *reg->mutable_unit() = RaidenIdToProto(Unit(rank));
      reg->add_shards(absl::StrCat("10.0.0.1:", 9000 + rank));
      reg->set_control_plane_rpc_address(
          absl::StrCat("10.0.0.1:", 9100 + rank));
      for (int s = 0; s < num_stages; ++s) {
        *reg->add_pools() = MakePool(absl::StrCat("fa.l", s), 1024, 1024, 16);
      }
      reg->set_layout_fingerprint("fp1");
      reg->set_page_tokens(512);
      reg->set_transfer_parallelism(num_src);
      reg->set_transfer_rank(rank);
      ASSERT_TRUE(Handle(req.SerializeAsString()).success());
    }
    for (int stage = 0; stage < num_stages; ++stage) {
      tpu_sync::rpc::ControlRequest req;
      req.set_command(
          tpu_sync::rpc::ControlRequest::COMMAND_REGISTER_WORK_UNIT);
      auto* reg = req.mutable_register_work_unit_request();
      *reg->mutable_unit() = RaidenIdToProto(PipelineStage(stage));
      reg->add_shards(absl::StrCat("10.0.0.2:", 9400 + stage));
      reg->set_control_plane_rpc_address(
          absl::StrCat("10.0.0.2:", 9600 + stage));
      *reg->add_pools() = MakePool(absl::StrCat("fa.l", stage), 1024, 1024, 16);
      reg->set_layout_fingerprint("fp1");
      reg->set_page_tokens(512);
      reg->set_transfer_parallelism(num_src);
      reg->set_transfer_rank(0);
      ASSERT_TRUE(Handle(req.SerializeAsString()).success());
    }
  }

  void RegisterTpPpSpans(const std::string& req_id, int64_t uuid, int num_src,
                         int num_stages) {
    for (int rank = 0; rank < num_src; ++rank) {
      tpu_sync::rpc::ControllerRequest req;
      req.set_command(
          tpu_sync::rpc::ControllerRequest::COMMAND_REGISTER_REQUEST_BLOCKS);
      auto* block_req = req.mutable_register_request_blocks_request();
      block_req->set_req_id(req_id);
      block_req->set_uuid(uuid);
      *block_req->mutable_unit() = RaidenIdToProto(Unit(rank));
      block_req->add_block_ids(3 + rank);
      for (int s = 0; s < num_stages; ++s) {
        auto* entry = block_req->add_pool_spans();
        entry->set_tag(absl::StrCat("fa.l", s));
        entry->add_block_ids(3 + rank);
        auto* span = entry->add_spans();
        span->set_src_block_ordinal(0);
        span->set_src_offset_bytes(0);
        span->set_dst_block_index(0);
        span->set_dst_offset_bytes(rank * 512);
        span->set_size_bytes(512);
        span->set_count(1);
        entry->set_declared_bytes(512);
        entry->set_dst_space_version(1);
      }
      tpu_sync::rpc::ControllerResponse resp = HandleController(req);
      ASSERT_TRUE(resp.success()) << resp.message();
    }
  }

  tpu_sync::rpc::ControllerResponse CoordinateStage(const std::string& req_id,
                                                    int64_t uuid, int num_src,
                                                    int stage) {
    tpu_sync::rpc::ControllerRequest req;
    req.set_command(
        tpu_sync::rpc::ControllerRequest::COMMAND_COORDINATE_TRANSFER);
    auto* coord = req.mutable_coordinate_transfer_request();
    for (int rank = 0; rank < num_src; ++rank) {
      *coord->add_src_units() = RaidenIdToProto(Unit(rank));
    }
    *coord->add_dst_units() = RaidenIdToProto(PipelineStage(stage));
    coord->set_uuid(uuid);
    coord->set_is_sender(true);
    coord->set_dst_mem_type(tpu_sync::rpc::MEMORY_TYPE_HBM);
    coord->set_use_block_chunks(true);
    coord->set_req_id(req_id);
    coord->add_dst_device_block_ids(7);
    coord->add_transfer_pool_tags(absl::StrCat("fa.l", stage));
    coord->add_dst_block_counts(1);
    return HandleController(req);
  }

  tpu_sync::rpc::ControllerResponse CompleteUnit(const std::string& req_id,
                                                 int64_t uuid, int rank) {
    tpu_sync::rpc::ControllerRequest req;
    req.set_command(
        tpu_sync::rpc::ControllerRequest::COMMAND_COMPLETE_REQUEST_BLOCKS);
    auto* comp = req.mutable_complete_request_blocks_request();
    comp->set_req_id(req_id);
    comp->set_uuid(uuid);
    *comp->mutable_unit() = RaidenIdToProto(Unit(rank));
    return HandleController(req);
  }

  tpu_sync::rpc::ControllerResponse CancelIfUnclaimed(const std::string& req_id,
                                                      int64_t uuid) {
    tpu_sync::rpc::ControllerRequest req;
    req.set_command(tpu_sync::rpc::ControllerRequest::
                        COMMAND_CANCEL_REQUEST_BLOCKS_IF_UNCLAIMED);
    req.mutable_cancel_request_blocks_if_unclaimed_request()->set_req_id(
        req_id);
    req.mutable_cancel_request_blocks_if_unclaimed_request()->set_uuid(uuid);
    return HandleController(req);
  }

  int RequestBlockStatusOf(const std::string& req_id, int64_t uuid) {
    tpu_sync::rpc::ControllerRequest req;
    req.set_command(
        tpu_sync::rpc::ControllerRequest::COMMAND_GET_REQUEST_BLOCK_STATUS);
    auto* key = req.mutable_get_request_block_status_request()->add_keys();
    key->set_req_id(req_id);
    key->set_uuid(uuid);
    tpu_sync::rpc::ControllerResponse resp = HandleController(req);
    EXPECT_TRUE(resp.success()) << resp.message();
    return resp.get_request_block_status_response().statuses(0);
  }

  FakeTransport transport_;
  double now_ = 1000.0;
  std::unique_ptr<ReshardService> service_;
};

// R7a: Two pipelined destination stages share one (req_id, uuid) claim under
// distinct claim_owner tokens. When stage 0's senders finish and call
// COMMAND_COMPLETE_REQUEST_BLOCKS, RequestBlockRegistry::Complete checks only
// completed_units_[key] == claimed_units_[key] (ignoring that
// claimed_owners_[key] still has 2 owners) and calls RetireLocked(key),
// erasing the request entry while stage 1 is still active.
TEST_F(ReshardBughuntTest,
       R7a_Stage0CompletionRetiresSharedClaimWhileStage1StillActive) {
  using ProtoStatus = tpu_sync::rpc::GetRequestBlockStatusResponse;
  RegisterTpPpUnits(/*num_src=*/2, /*num_stages=*/2);
  RegisterTpPpSpans("req-r7a", 701, /*num_src=*/2, /*num_stages=*/2);

  // Stage 0 and Stage 1 both claim ("req-r7a", 701) under distinct
  // claim_owner tokens (claimed_owners_.size() == 2).
  ASSERT_TRUE(
      CoordinateStage("req-r7a", 701, /*num_src=*/2, /*stage=*/0).success());
  ASSERT_TRUE(
      CoordinateStage("req-r7a", 701, /*num_src=*/2, /*stage=*/1).success());
  EXPECT_EQ(RequestBlockStatusOf("req-r7a", 701), ProtoStatus::STATUS_CLAIMED);

  // Stage 0's senders (Unit(0) and Unit(1)) finish sending fa.l0 and report
  // COMMAND_COMPLETE_REQUEST_BLOCKS. Stage 1 (fa.l1) is still in flight.
  EXPECT_EQ(CompleteUnit("req-r7a", 701, /*rank=*/0).response_data(), "0");
  tpu_sync::rpc::ControllerResponse stage0_done =
      CompleteUnit("req-r7a", 701, /*rank=*/1);

  // BUG (R7a): Complete retires the entry (returning 2 retired rows) on stage
  // 0's votes alone even though stage 1's claim_owner is still registered in
  // claimed_owners_.
  EXPECT_EQ(stage0_done.response_data(), "2");
  EXPECT_EQ(RequestBlockStatusOf("req-r7a", 701), ProtoStatus::STATUS_UNKNOWN);

  // When stage 1's senders finish fa.l1 and report Complete, or if stage 1
  // retries CoordinateStage, the entry has already been wiped.
  EXPECT_EQ(CompleteUnit("req-r7a", 701, /*rank=*/0).response_data(), "0");
  EXPECT_EQ(CompleteUnit("req-r7a", 701, /*rank=*/1).response_data(), "0");
  tpu_sync::rpc::ControllerResponse stage1_retry =
      CoordinateStage("req-r7a", 701, /*num_src=*/2, /*stage=*/1);
  EXPECT_FALSE(stage1_retry.success());
  EXPECT_THAT(stage1_retry.message(),
              HasSubstr("Missing producer block registration"));
}

// R7b: RequestBlockRegistry::AbandonClaim erases claimed_ and claimed_units_
// when the last claim_owner leaves, but forgets to erase completed_units_.
// Stale completion votes from a partially completed prior claim carry over into
// the next claim and cause premature retirement.
TEST_F(ReshardBughuntTest,
       R7b_AbandonClaimLeavesStaleCompletionVotesThatPrematurelyRetireNextClaim) {
  using Status = RequestBlockRegistry::RequestBlockStatus;
  RegisterTpPpUnits(/*num_src=*/2, /*num_stages=*/1);
  RegisterTpPpSpans("req-r7b", 702, /*num_src=*/2, /*num_stages=*/1);

  RequestBlockRegistry* registry = service_->registry();
  const void* owner_1 = reinterpret_cast<const void*>(uintptr_t{0x1001});
  const void* owner_2 = reinterpret_cast<const void*>(uintptr_t{0x1002});

  // First claim by owner_1 over {Unit(0), Unit(1)}.
  ASSERT_TRUE(
      registry->LookupAndClaim("req-r7b", 702, {Unit(0), Unit(1)}, owner_1)
          .ok());
  // Unit(0) records a completion vote before owner_1 abandons the claim.
  ASSERT_EQ(*registry->Complete("req-r7b", 702, Unit(0)), 0);
  registry->AbandonClaim("req-r7b", 702, owner_1);
  EXPECT_EQ(registry->Status({{"req-r7b", 702}})[0], Status::kRegistered);

  // Second claim by owner_2 over {Unit(0), Unit(1)}.
  ASSERT_TRUE(
      registry->LookupAndClaim("req-r7b", 702, {Unit(0), Unit(1)}, owner_2)
          .ok());

  // BUG (R7b): Because AbandonClaim did not clear completed_units_[{"req-r7b",
  // 702}], Unit(0)'s stale vote from owner_1's abandoned claim is still present.
  // As soon as Unit(1) votes under owner_2, Complete sees {Unit(0), Unit(1)} ==
  // claimed_units_ and retires the request (returning 2 retired rows) before
  // Unit(0) has completed under owner_2.
  absl::StatusOr<int> retired_early =
      registry->Complete("req-r7b", 702, Unit(1));
  ASSERT_TRUE(retired_early.ok());
  EXPECT_EQ(*retired_early, 2);
  EXPECT_EQ(registry->Status({{"req-r7b", 702}})[0], Status::kUnknown);
}

// R8: RequestBlockRegistry::EvictExpiredLocked evicts request_blocks_[key]
// using (now - registered_at) > ttl_s without checking claimed_.contains(key),
// while claimed_[key] is evicted using (now - claimed_at) > ttl_s.
TEST_F(ReshardBughuntTest,
       R8_SplitTtlEvictsRequestBlocksWhileClaimIsStillActive) {
  using ProtoStatus = tpu_sync::rpc::GetRequestBlockStatusResponse;
  RegisterTpPpUnits(/*num_src=*/2, /*num_stages=*/2);

  // Register at t = 1000.0 (ttl_s = 60.0, so registration expires at 1060.0).
  now_ = 1000.0;
  RegisterTpPpSpans("req-r8", 801, /*num_src=*/2, /*num_stages=*/2);

  // Stage 0 claims at t = 1040.0 (claim expires at 1100.0).
  now_ = 1040.0;
  ASSERT_TRUE(
      CoordinateStage("req-r8", 801, /*num_src=*/2, /*stage=*/0).success());

  // Advance to t = 1070.0:
  //   * now - claimed_at    = 30.0s <= 60.0s (claim is still active)
  //   * now - registered_at = 70.0s >  60.0s (registration timestamp expired)
  now_ = 1070.0;

  // GetStatus still reports STATUS_CLAIMED because claimed_ has not expired,
  // and EvictExpiredLocked Pass 1 already purged request_blocks_["req-r8", 801].
  EXPECT_EQ(RequestBlockStatusOf("req-r8", 801), ProtoStatus::STATUS_CLAIMED);

  // BUG (R8): Stage 1's CoordinateStage fails with "Missing producer block
  // registration" even though Stage 0's claim is still active and within TTL.
  tpu_sync::rpc::ControllerResponse stage1 =
      CoordinateStage("req-r8", 801, /*num_src=*/2, /*stage=*/1);
  EXPECT_FALSE(stage1.success());
  EXPECT_THAT(stage1.message(),
              HasSubstr("Missing producer block registration"));
}

// R2b: ReshardCoordinator::ExecutePoolReshard abandons its registry claim when
// BuildPoolReshardPlan fails (:422) or when receiver arming fails (:460), but
// if receiver arming succeeds and sender dispatch fails (:522-544), it returns
// the error without calling registry_->AbandonClaim(req_id, uuid, claim_owner)
// and without aborting the armed receiver.
TEST_F(ReshardBughuntTest,
       R2b_SenderDispatchFailureOrphansRegistryClaimAndArmedReceiver) {
  using ProtoStatus = tpu_sync::rpc::GetRequestBlockStatusResponse;
  RegisterTpPpUnits(/*num_src=*/1, /*num_stages=*/1);
  RegisterTpPpSpans("req-r2b", 202, /*num_src=*/1, /*num_stages=*/1);

  // Receiver (10.0.0.2:9600) succeeds its arm, but sender (10.0.0.1:9100)
  // fails its dispatch.
  transport_.FailFor("10.0.0.1:9100");
  tpu_sync::rpc::ControllerResponse coord =
      CoordinateStage("req-r2b", 202, /*num_src=*/1, /*stage=*/0);
  ASSERT_FALSE(coord.success());
  EXPECT_THAT(coord.message(), HasSubstr("injected worker rpc failure"));

  // Receiver was armed (call 0) and sender dispatch was attempted (call 1),
  // with no rollback RPC sent to the armed receiver.
  ASSERT_EQ(transport_.calls_.size(), 2u);
  EXPECT_EQ(transport_.calls_[0].first, "10.0.0.2:9600");
  EXPECT_EQ(transport_.calls_[1].first, "10.0.0.1:9100");

  // BUG (R2b): Because ExecutePoolReshard did not call AbandonClaim on sender
  // dispatch failure, the request remains permanently stuck in STATUS_CLAIMED
  // and CancelIfUnclaimed refuses to cancel it.
  EXPECT_EQ(RequestBlockStatusOf("req-r2b", 202), ProtoStatus::STATUS_CLAIMED);
  EXPECT_EQ(CancelIfUnclaimed("req-r2b", 202).response_data(), "false");
}

}  // namespace
}  // namespace reshard
}  // namespace kv_cache
}  // namespace tpu_raiden
