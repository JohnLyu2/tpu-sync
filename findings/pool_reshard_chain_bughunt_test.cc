// Copyright 2026 Google LLC.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Hardware-free reproduction for candidate 1A (tpu-sync 42dda542):
// a windowed (multi-sub-plan) pool-reshard request whose sender participates
// in only m < K of the K sub-plans never reports done_sending for that sender;
// instead the sender's KVCacheManagerWithTransfer fails the request with
// "pool reshard sub-plan chain stalled" one transfer timeout later.
//
// Chain of facts at 42dda542:
//   * BuildPoolReshardPlan (tpu_sync/kv_cache/reshard/pool_reshard_planner.cc,
//     `plan.src_units` loop) keeps only the source units with schedule entries
//     in the current window.
//   * ReshardCoordinator::RunSubPlan (tpu_sync/kv_cache/reshard/
//     reshard_coordinator.cc) stamps every sub-plan with
//     `sub_plan_index = index; sub_plan_count = ctx->chain.count` (the global
//     K) and dispatches StartTransfer only to `plan.src_units`. Nothing else
//     tells a skipped sender about the windows it is not part of.
//   * Upstream's own ReshardStackTest.WindowClipsStraddlingSpansAtWindowBoundaries
//     (tpu_sync/kv_cache/reshard/reshard_service_test.cc) pins that shape:
//     K = 2, "Sub-transfer 0: arm + two senders; sub-transfer 1: arm + rank 1
//     only" -- rank 0 receives exactly one sender plan, stamped
//     sub_plan_index 0, sub_plan_count 2.
//   * On the sender, KVCacheManagerWithTransfer::PoolReshardPush ->
//     NoteSubPlanRegisteredLocked sets send_chains_[req_id].count = K;
//     RecordPoolReshardTerminalLocked inserts req_id into done_sending_ only
//     once `settled.size() >= count`; SweepSubPlanChainsLocked, after
//     timeout_s_ with no active send session for req_id, inserts req_id into
//     failed_recving_ with "pool reshard sub-plan chain stalled: m of K ...".
//
// Harness: a real KVCacheManagerWithTransfer. Each sender sub-plan is
// registered exactly as PoolReshardPush does (ReshardSendSession::Create,
// insert into active_pool_reshard_sends_, NoteSubPlanRegisteredLocked); the
// one step skipped is ReshardSendSession::ExecutePush, whose D2H copy and TCP
// push need a device. In its place the session is settled successfully via
// its own Finish(OkStatus()), i.e. the same terminal state (done_, status_ OK)
// a successful push reaches. Reporting then runs through the production
// CompleteReadWithDetails (RecordPoolReshardTerminalLocked +
// SweepSubPlanChainsLocked).
//
// ControlSenderInEverySubPlanReportsDone passes (the harness works). The two
// SenderInOnlySomeSubPlans* tests assert the expected contract (a sender whose
// every dispatched sub-plan succeeded reports done_sending, and is never
// failed) and therefore FAIL on unmodified 42dda542.

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "absl/status/status.h"
#include "absl/status/status_macros.h"
#include "absl/status/status_matchers.h"
#include "absl/status/statusor.h"
#include "absl/strings/str_cat.h"
#include "absl/strings/string_view.h"
#include "absl/synchronization/mutex.h"
#include "absl/time/clock.h"
#include "absl/time/time.h"
#include "tpu_sync/common/control_pipe/control_pipe_client.h"
#include "tpu_sync/common/control_pipe/control_pipe_types.h"
#include "tpu_sync/common/raiden_id.h"
#include "tpu_sync/kv_cache/kv_cache_manager_with_transfer.h"
#include "tpu_sync/kv_cache/pool_layout.h"
#include "tpu_sync/kv_cache/reshard/declaration_types.h"
#include "tpu_sync/kv_cache/reshard/reshard_coordinator.h"
#include "tpu_sync/kv_cache/reshard/reshard_service.h"
#include "tpu_sync/kv_cache/reshard_receive_session.h"
#include "tpu_sync/kv_cache/reshard_send_session.h"
#include "tpu_sync/proto/control_pipe.pb.h"
#include "tpu_sync/rpc/controller_service.pb.h"
#include "tpu_sync/rpc/raiden_service.pb.h"

namespace tpu_raiden {

// Candidate 1B test peers (same shape as upstream's own peers in
// kv_cache_manager_with_transfer_pool_reshard_test.cc and
// reshard_send_session_test.cc; both structs are friends of the sessions).
struct PoolReshardRecvTestPeer {
  static void FinishPoolH2d(ReshardReceiveSession& session,
                            KVCacheManagerWithTransfer& manager,
                            size_t pool_idx, const absl::Status& status) {
    session.FinishPoolH2d(manager, pool_idx, status);
  }
};

struct ReshardSendSessionTestPeer {
  // Counts one (pool, peer) push of `session` in flight, as ExecutePush and
  // StartPoolPush do before issuing it.
  static void BeginPush(ReshardSendSession& session,
                        KVCacheManagerWithTransfer& manager) {
    absl::MutexLock lock(session.mu_);
    session.manager_ = &manager;
    ++session.in_flight_;
  }
  // Ends that push the way its AsyncPush completion callback does.
  static void CompletePush(ReshardSendSession& session,
                           KVCacheManagerWithTransfer& manager,
                           const absl::Status& status) {
    session.RecordPushCompletion(manager, status);
    session.EndOp();
  }
};

namespace {

using ::tpu_sync::rpc::MEMORY_TYPE_HBM;
using ::tpu_sync::rpc::StartTransferRequest;

constexpr char kReqId[] = "windowed_req";
constexpr double kTimeoutS = 0.05;

class SenderChainManager : public KVCacheManagerWithTransfer {
 public:
  explicit SenderChainManager(double timeout_s)
      : KVCacheManagerWithTransfer(
            /*num_layers=*/1, /*num_shards=*/1,
            /*slice_byte_size=*/128,
            /*local_port=*/std::nullopt,
            /*host_blocks_to_allocate=*/std::make_optional(4),
            /*parallelism=*/1, /*node_id=*/0,
            /*local_control_port=*/-1, /*max_blocks=*/0, /*num_slots=*/0,
            timeout_s) {}

  void AttachPlaceholderDeviceHold() {
    base()->AttachPlaceholderDeviceHoldForTest();
  }

  // PoolReshardPush (kv_cache_manager_with_transfer.cc) verbatim up to
  // `state->ExecutePush(...)`; the device push is replaced by settling the
  // session successfully, as a push whose every (pool, peer) completion
  // succeeded does.
  absl::Status PushSenderSubPlanThatSucceeds(
      const StartTransferRequest& plan,
      const std::vector<int64_t>& src_block_ids) {
    ABSL_ASSIGN_OR_RETURN(
        std::shared_ptr<ReshardSendSession> state,
        ReshardSendSession::Create(base_.get(), staging_allocator_.get(),
                                   src_block_ids, /*parallelism=*/1,
                                   DeadlineFromNow(), plan));
    {
      absl::MutexLock lock(mu_);
      active_pool_reshard_sends_[plan.uuid()] = state;
      NoteSubPlanRegisteredLocked(/*is_recv=*/false, plan.req_id(),
                                  plan.uuid(), plan.sub_plan_index(),
                                  plan.sub_plan_count());
    }
    state->Finish(absl::OkStatus());
    if (!state->Done() || !state->GetStatus().ok()) {
      return absl::InternalError("sender sub-plan did not settle OK");
    }
    return absl::OkStatus();
  }
};

kv_cache::PoolSpec DensePool() {
  return kv_cache::PoolSpec{
      .tag = "fa",
      .storage_index = 0,
      .base_offset_bytes = 0,
      .block_stride_bytes = 128,
      .num_blocks = 4,
      .regions = {kv_cache::RegionSpec{
          .name = "block",
          .offset_bytes = 0,
          .stride_bytes = 128,
          .unit_bytes = 128,
          .num_units = 1,
          .units_per_stride = 1,
      }},
      .dtype_tag = "bf16",
  };
}

// The sender plan RunSubPlan dispatches for window `index` of a K-window
// request: one schedule entry (local key 0) pushing source block `index` to
// destination block `index`, stamped with the global chain position.
StartTransferRequest SenderSubPlan(int64_t uuid, int32_t index,
                                   int32_t count) {
  StartTransferRequest plan;
  plan.set_uuid(uuid);
  plan.set_req_id(kReqId);
  plan.set_is_sender(true);
  plan.set_dst_mem_type(MEMORY_TYPE_HBM);
  plan.set_use_block_chunks(true);
  plan.set_parallelism(1);
  plan.add_transfer_pool_indices(0);
  plan.add_pool_dtype_tags("bf16");
  auto* group = plan.add_pool_groups();
  group->add_pool_indices(0);
  group->add_dst_device_block_ids(index);
  group->set_expected_pushes(1);
  group->add_dst_expected_extent_bytes(16);
  plan.set_sub_plan_index(index);
  plan.set_sub_plan_count(count);
  auto* entry = (*plan.mutable_shard_push_schedules())[0].add_entries();
  entry->set_dst_peer("127.0.0.1:1");
  entry->set_dst_shard_idx(0);
  entry->set_src_block_id(index);
  entry->set_dst_block_id(index);
  entry->set_src_offset_bytes(0);
  entry->set_dst_offset_bytes(0);
  entry->set_size_bytes(16);
  entry->set_src_stride_bytes(0);
  entry->set_dst_stride_bytes(0);
  entry->set_count(1);
  return plan;
}

void PrintCompletions(const std::string& label, const CompleteReadResult& r) {
  std::cerr << "[1A] " << label << ": sent={";
  for (const auto& id : r.sent) std::cerr << id << ",";
  std::cerr << "} failed={";
  for (const auto& id : r.failed) std::cerr << id << ",";
  std::cerr << "}";
  if (auto it = r.details.find(kReqId); it != r.details.end()) {
    std::cerr << " details[" << kReqId
              << "].reason=" << it->second.reason.value_or("<none>");
  }
  std::cerr << "\n";
}

// Drives the sender through the sub-plans in `dispatched` (all of K = 2,
// all succeeding), then polls once right away and once after > timeout_s_.
void RunSenderChain(const std::vector<int32_t>& dispatched, int32_t count) {
  SenderChainManager manager(kTimeoutS);
  ASSERT_TRUE(manager.base()->RegisterPools({DensePool()}).ok());
  manager.AttachPlaceholderDeviceHold();

  for (int32_t index : dispatched) {
    ABSL_ASSERT_OK(manager.PushSenderSubPlanThatSucceeds(
        SenderSubPlan(/*uuid=*/9000 + index, index, count),
        std::vector<int64_t>{index}));
  }

  // One poll right away, then polls past the timeout: the request must have
  // reported by then.
  bool reported_sent = false;
  bool reported_failed = false;
  std::string failure_reason;
  for (int i = 0; i < 4; ++i) {
    if (i > 0) absl::SleepFor(absl::Milliseconds(60));
    CompleteReadResult r = manager.CompleteReadWithDetails();
    PrintCompletions(absl::StrCat("poll at +", i * 60,
                                  "ms after settling (timeout_s=", kTimeoutS,
                                  ")"),
                     r);
    reported_sent |=
        std::find(r.sent.begin(), r.sent.end(), kReqId) != r.sent.end();
    if (std::find(r.failed.begin(), r.failed.end(), kReqId) != r.failed.end()) {
      reported_failed = true;
      failure_reason = r.details.contains(kReqId)
                           ? r.details.at(kReqId).reason.value_or("")
                           : "";
    }
  }

  EXPECT_TRUE(reported_sent)
      << "sender settled every sub-plan it was dispatched ("
      << dispatched.size() << " of sub_plan_count=" << count
      << ") successfully, but req_id never appeared in done_sending";
  EXPECT_FALSE(reported_failed)
      << "sender whose every dispatched sub-plan succeeded was reported "
         "failed: "
      << failure_reason;
}

TEST(PoolReshardChainBughunt, ControlSenderInEverySubPlanReportsDone) {
  RunSenderChain(/*dispatched=*/{0, 1}, /*count=*/2);
}

// Rank 0 in ReshardStackTest.WindowClipsStraddlingSpansAtWindowBoundaries:
// its bytes all fall in window 0, so window 1's plan omits it.
TEST(PoolReshardChainBughunt,
     SenderInOnlySomeSubPlansFirstWindowOnlyNeverReportsDone) {
  RunSenderChain(/*dispatched=*/{0}, /*count=*/2);
}

// The mirror shape: a rank whose bytes all fall in the last window (its
// chain entry is never anchored by a sub-plan 0).
TEST(PoolReshardChainBughunt,
     SenderInOnlySomeSubPlansLastWindowOnlyNeverReportsDone) {
  RunSenderChain(/*dispatched=*/{1}, /*count=*/2);
}

// ===========================================================================
// Candidate 1B: the first failing sub-plan publishes failed_recving while a
// sibling sub-plan of the same req_id is still live, and later sub-plans of
// an already-failed chain are still accepted and run.
//
//   * RecordPoolReshardTerminalLocked (kv_cache_manager_with_transfer.cc)
//     inserts req_id into failed_recving_ on the first !ok sub-plan terminal
//     without looking at active_pool_reshard_recvs_ / _sends_ for other live
//     sessions of the same req_id.
//   * PoolReshardRegisterRecv / PoolReshardPush never consult recv_chains_ /
//     send_chains_ `failed` before creating a session (plan claim, staging
//     leases); the late sub-plan's terminal is then dropped by the
//     `if (progress.failed) return;` early-out.
//   * Once SweepSubPlanChainsLocked has erased a failed chain (one timeout
//     after the failure), a late sub-plan starts a fresh, unanchored chain
//     entry that is later failed AGAIN by the stall sweep: req_id reported in
//     failed_recving twice.
//
// RecvFailure*/SenderFailure* assert "no failed_recving while a sibling
// sub-plan of the request is still live"; RecvLaterSubPlan* asserts "a
// sub-plan of a chain already reported failed is refused";
// RecvLateSubPlanAfterSweep* asserts "a request is reported failed at most
// once". Each FAILS on unmodified 42dda542 if the defect is present.
// ===========================================================================

class ChainManager : public SenderChainManager {
 public:
  using SenderChainManager::SenderChainManager;
  using KVCacheManagerWithTransfer::PoolReshardRegisterRecv;

  std::shared_ptr<ReshardReceiveSession> RecvSession(uint64_t uuid) {
    absl::MutexLock lock(mu_);
    auto it = active_pool_reshard_recvs_.find(uuid);
    return it == active_pool_reshard_recvs_.end() ? nullptr : it->second;
  }

  void FinishRecvPool(uint64_t uuid, size_t pool_idx,
                      const absl::Status& status) {
    std::shared_ptr<ReshardReceiveSession> session = RecvSession(uuid);
    if (session == nullptr) return;
    PoolReshardRecvTestPeer::FinishPoolH2d(*session, *this, pool_idx, status);
  }

  // PoolReshardPush up to (not including) ExecutePush; the caller drives the
  // push accounting through ReshardSendSessionTestPeer.
  absl::StatusOr<std::shared_ptr<ReshardSendSession>> RegisterSenderSubPlan(
      const StartTransferRequest& plan,
      const std::vector<int64_t>& src_block_ids) {
    ABSL_ASSIGN_OR_RETURN(
        std::shared_ptr<ReshardSendSession> state,
        ReshardSendSession::Create(base_.get(), staging_allocator_.get(),
                                   src_block_ids, /*parallelism=*/1,
                                   DeadlineFromNow(), plan));
    absl::MutexLock lock(mu_);
    active_pool_reshard_sends_[plan.uuid()] = state;
    NoteSubPlanRegisteredLocked(/*is_recv=*/false, plan.req_id(), plan.uuid(),
                                plan.sub_plan_index(), plan.sub_plan_count());
    return state;
  }
};

// Receiver plan for window `index` of a K-window request: one source rank
// pushing 16 bytes into destination block `index` of pool 0.
StartTransferRequest RecvSubPlan(int64_t uuid, int32_t index, int32_t count) {
  StartTransferRequest plan = SenderSubPlan(uuid, index, count);
  plan.set_is_sender(false);
  return plan;
}

bool Reports(const std::vector<std::string>& ids) {
  return std::find(ids.begin(), ids.end(), kReqId) != ids.end();
}

std::string RecvState(const char* name, const ReshardReceiveSession& s) {
  return absl::StrCat(name, "{Done=", s.Done(), " IsDraining=", s.IsDraining(),
                      " HasPendingWork=", s.HasPendingWork(),
                      " status=", s.GetStatus().ToString(), "}");
}

std::string SendState(const char* name, const ReshardSendSession& s) {
  return absl::StrCat(name, "{Done=", s.Done(), " IsDraining=", s.IsDraining(),
                      " status=", s.GetStatus().ToString(), "}");
}

void SetUpChainManager(ChainManager& manager) {
  ASSERT_TRUE(manager.base()->RegisterPools({DensePool()}).ok());
  manager.AttachPlaceholderDeviceHold();
}

// (a) Receiver: sub-plans 0 and 1 of K=2 armed on one manager (bounded
// staging can hold both windows). Sub-plan 1 has an admitted push in flight
// (BeginIncomingPush, the transport hook a real push takes); sub-plan 0's
// push fails mid-stream (EndIncomingPush with an error).
TEST(PoolReshardChainBughunt1B,
     RecvFailureNotReportedWhileSiblingSubPlanActive) {
  ChainManager manager(/*timeout_s=*/30.0);
  SetUpChainManager(manager);

  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      RecvSubPlan(7100, /*index=*/0, /*count=*/2), std::vector<int64_t>{0}));
  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      RecvSubPlan(7101, /*index=*/1, /*count=*/2), std::vector<int64_t>{1}));
  std::shared_ptr<ReshardReceiveSession> sub0 = manager.RecvSession(7100);
  std::shared_ptr<ReshardReceiveSession> sub1 = manager.RecvSession(7101);
  ASSERT_NE(sub0, nullptr);
  ASSERT_NE(sub1, nullptr);

  ABSL_ASSERT_OK(manager.base()->BeginIncomingPush(7101));
  ABSL_ASSERT_OK(manager.base()->BeginIncomingPush(7100));
  const absl::Status end0 = manager.base()->EndIncomingPush(
      7100, absl::UnavailableError("peer reset mid-push"));
  std::cerr << "[1B-a] EndIncomingPush(sub-plan 0, error) -> " << end0 << "\n";

  CompleteReadResult r = manager.CompleteReadWithDetails();
  PrintCompletions("1B-a poll after sub-plan 0 failed", r);
  const std::string sibling = RecvState("sub-plan 1", *sub1);
  std::cerr << "[1B-a] at that poll: " << RecvState("sub-plan 0", *sub0)
            << " " << sibling << "\n";
  EXPECT_FALSE(Reports(r.failed) && !sub1->Done())
      << "failed_recving published for " << kReqId
      << " while sibling sub-plan 1 is still live: " << sibling;

  // Teardown: end sub-plan 1's push and let it settle cleanly.
  std::cerr << "[1B-a] EndIncomingPush(sub-plan 1, ok) -> "
            << manager.base()->EndIncomingPush(7101, absl::OkStatus()) << "\n";
  manager.FinishRecvPool(7101, /*pool_idx=*/0, absl::OkStatus());
  PrintCompletions("1B-a poll after sub-plan 1 settled OK",
                   manager.CompleteReadWithDetails());
  std::cerr << "[1B-a] final " << RecvState("sub-plan 1", *sub1) << "\n";
}

// (b) Receiver: once the chain's failure has been reported, a further
// sub-plan of it is still armed (plan claimed, staging leased, session live)
// and its clean terminal is silently swallowed.
TEST(PoolReshardChainBughunt1B,
     RecvLaterSubPlanAcceptedAfterChainFailureReported) {
  ChainManager manager(/*timeout_s=*/30.0);
  SetUpChainManager(manager);

  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      RecvSubPlan(7200, /*index=*/0, /*count=*/2), std::vector<int64_t>{0}));
  ABSL_ASSERT_OK(manager.base()->BeginIncomingPush(7200));
  manager.base()
      ->EndIncomingPush(7200, absl::UnavailableError("peer reset mid-push"))
      .IgnoreError();
  CompleteReadResult first = manager.CompleteReadWithDetails();
  PrintCompletions("1B-b poll after sub-plan 0 failed", first);
  ASSERT_TRUE(Reports(first.failed)) << "precondition: failure reported";

  const absl::Status late = manager.PoolReshardRegisterRecv(
      RecvSubPlan(7201, /*index=*/1, /*count=*/2), std::vector<int64_t>{1});
  std::shared_ptr<ReshardReceiveSession> sub1 = manager.RecvSession(7201);
  const bool claimed = manager.base()->HasActivePlan(7201);
  std::cerr << "[1B-b] PoolReshardRegisterRecv(sub-plan 1 of failed chain) -> "
            << late << "; plan claimed=" << claimed
            << " session=" << (sub1 ? RecvState("sub-plan 1", *sub1) : "none")
            << "\n";
  EXPECT_FALSE(late.ok())
      << "sub-plan 1 of a chain already reported failed was accepted";
  EXPECT_FALSE(claimed) << "the late sub-plan claimed its plan uuid";
  EXPECT_EQ(sub1, nullptr) << "the late sub-plan has a live receive session";

  if (sub1 != nullptr) {
    manager.FinishRecvPool(7201, /*pool_idx=*/0, absl::OkStatus());
    CompleteReadResult after = manager.CompleteReadWithDetails();
    PrintCompletions("1B-b poll after the late sub-plan settled OK", after);
    std::cerr << "[1B-b] late sub-plan terminal swallowed: received="
              << Reports(after.received) << " failed=" << Reports(after.failed)
              << "\n";
  }
}

// (b') Receiver: the failed chain entry is erased one timeout after the
// failure; a late sub-plan then re-creates an unanchored chain that the
// stall sweep fails again -- the request is reported failed twice.
TEST(PoolReshardChainBughunt1B,
     RecvLateSubPlanAfterSweepReportsTheFailureAgain) {
  ChainManager manager(kTimeoutS);
  SetUpChainManager(manager);

  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      RecvSubPlan(7300, /*index=*/0, /*count=*/2), std::vector<int64_t>{0}));
  ABSL_ASSERT_OK(manager.base()->BeginIncomingPush(7300));
  manager.base()
      ->EndIncomingPush(7300, absl::UnavailableError("peer reset mid-push"))
      .IgnoreError();
  int failed_reports = 0;
  CompleteReadResult r = manager.CompleteReadWithDetails();
  PrintCompletions("1B-b' poll after sub-plan 0 failed", r);
  failed_reports += Reports(r.failed);
  absl::SleepFor(absl::Milliseconds(120));
  r = manager.CompleteReadWithDetails();  // sweep erases the failed chain
  PrintCompletions("1B-b' poll +120ms (failed chain erased)", r);
  failed_reports += Reports(r.failed);

  ABSL_ASSERT_OK(manager.PoolReshardRegisterRecv(
      RecvSubPlan(7301, /*index=*/1, /*count=*/2), std::vector<int64_t>{1}));
  manager.FinishRecvPool(7301, /*pool_idx=*/0, absl::OkStatus());
  for (int i = 0; i < 3; ++i) {
    if (i > 0) absl::SleepFor(absl::Milliseconds(60));
    r = manager.CompleteReadWithDetails();
    PrintCompletions(absl::StrCat("1B-b' poll +", i * 60,
                                  "ms after late sub-plan 1 settled OK"),
                     r);
    failed_reports += Reports(r.failed);
  }
  EXPECT_EQ(failed_reports, 1)
      << kReqId << " was reported in failed_recving " << failed_reports
      << " times";
}

// (c) Sender: sub-plans 0 and 1 of K=2 live on one manager, each with one
// push in flight; sub-plan 0's push completes with an error.
TEST(PoolReshardChainBughunt1B,
     SenderFailureNotReportedWhileSiblingSubPlanActive) {
  ChainManager manager(/*timeout_s=*/30.0);
  SetUpChainManager(manager);

  absl::StatusOr<std::shared_ptr<ReshardSendSession>> sub0 =
      manager.RegisterSenderSubPlan(SenderSubPlan(7400, 0, 2), {0});
  absl::StatusOr<std::shared_ptr<ReshardSendSession>> sub1 =
      manager.RegisterSenderSubPlan(SenderSubPlan(7401, 1, 2), {1});
  ABSL_ASSERT_OK(sub0);
  ABSL_ASSERT_OK(sub1);
  ReshardSendSessionTestPeer::BeginPush(**sub1, manager);
  ReshardSendSessionTestPeer::BeginPush(**sub0, manager);
  ReshardSendSessionTestPeer::CompletePush(
      **sub0, manager, absl::UnavailableError("peer reset mid-push"));

  CompleteReadResult r = manager.CompleteReadWithDetails();
  PrintCompletions("1B-c poll after sender sub-plan 0 failed", r);
  const std::string sibling = SendState("sub-plan 1", **sub1);
  std::cerr << "[1B-c] at that poll: " << SendState("sub-plan 0", **sub0)
            << " " << sibling << "\n";
  EXPECT_FALSE(Reports(r.failed) && !(*sub1)->Done())
      << "failed_recving published for sender " << kReqId
      << " while sibling sub-plan 1 still has a push in flight: " << sibling;

  // Teardown: sub-plan 1's push lands cleanly.
  ReshardSendSessionTestPeer::CompletePush(**sub1, manager, absl::OkStatus());
  CompleteReadResult after = manager.CompleteReadWithDetails();
  PrintCompletions("1B-c poll after sender sub-plan 1 settled OK", after);
  std::cerr << "[1B-c] final " << SendState("sub-plan 1", **sub1) << "\n";
}

}  // namespace

// ===========================================================================
// Candidate 1C: a chain that fails at sub-plan index >= 1 never abandons the
// request's registry claim. RunSubPlan abandons only `if (index == 0)`
// (reshard_coordinator.cc), and StartChain does not abandon either; the
// header (reshard_coordinator.h, RunSubPlan) says later sub-transfers "leave
// the claim to the dispatched senders' terminals". The claim's expected
// voters are every coordinated source unit (LookupAndClaim is called with
// request.src_units = args.src_units for every window), so a source unit
// that was never dispatched in windows 0..index-1 has no session, no
// terminal and never votes Complete: the claim stays STATUS_CLAIMED (and
// CancelIfUnclaimed refuses) until the registry TTL.
//
// Fixture: the minimal pieces of upstream's ReshardStackTest
// (tpu_sync/kv_cache/reshard/reshard_service_test.cc): a real ReshardService
// over a FakeTransport that captures worker payloads, with an injected clock.
// Topology: 2 source ranks, 1 destination, 4 destination pages, window = 2
// pages -> K = 2; rank 0 owns pages 0-1 (window 0 only), rank 1 owns pages
// 2-3 (window 1 only). Sub-plan 1's receiver arm is hard-refused.
// ===========================================================================

namespace kv_cache {
namespace reshard {
namespace {

using ProtoStatus = ::tpu_sync::rpc::GetRequestBlockStatusResponse;

constexpr double kTtlS = 600.0;
constexpr char kDstCtrl[] = "10.0.0.2:9600";

RaidenId Src(int rank) {
  RaidenId id;
  id.job_name = "prefill";
  id.job_replica_id = absl::StrCat(rank);
  id.data_name = "kv_cache";
  id.data_replica_idx = 0;
  return id;
}

RaidenId Dst() {
  RaidenId id;
  id.job_name = "decode";
  id.job_replica_id = "0";
  id.data_name = "kv_cache";
  id.data_replica_idx = 0;
  return id;
}

tpu_sync::rpc::PoolSpecProto FaPool() {
  tpu_sync::rpc::PoolSpecProto pool;
  pool.set_tag("fa");
  pool.set_storage_index(0);
  pool.set_base_offset_bytes(0);
  pool.set_block_stride_bytes(1024);
  pool.set_num_blocks(16);
  pool.set_dtype_tag("uint8");
  auto* region = pool.add_regions();
  region->set_name("live");
  region->set_offset_bytes(0);
  region->set_stride_bytes(1024);
  region->set_unit_bytes(1024);
  region->set_num_units(1);
  region->set_units_per_stride(1);
  return pool;
}

// Captures worker payloads; refuses `fail_addr_` always, or `fail_after_addr_`
// after its first `fail_after_` calls (as upstream's FakeTransport does).
class ArmRefusingTransport final : public ControlPipeClient {
 public:
  absl::StatusOr<control_pipe::proto::ControlResponseEnvelope> SendRaw(
      absl::string_view endpoint,
      const control_pipe::proto::ControlEnvelope& envelope,
      absl::Duration /*timeout*/) override {
    absl::MutexLock lock(mu_);
    calls_.emplace_back(std::string(endpoint), envelope.payload());
    size_t calls_to_endpoint = 0;
    for (const auto& [addr, payload] : calls_) {
      if (addr == endpoint) ++calls_to_endpoint;
    }
    control_pipe::proto::ControlResponseEnvelope resp_env;
    resp_env.set_request_id(envelope.request_id());
    resp_env.set_status_code(0);
    tpu_sync::rpc::ControlResponse resp;
    if (fail_addr_ == endpoint ||
        (fail_after_addr_ == endpoint && calls_to_endpoint > fail_after_)) {
      resp.set_success(false);
      resp.set_message("injected arm refusal");
    } else {
      resp.set_success(true);
    }
    resp_env.set_payload(resp.SerializeAsString());
    return resp_env;
  }
  ControlPipeBackendType backend_type() const override {
    return ControlPipeBackendType::kTcp;
  }

  absl::Mutex mu_;
  std::vector<std::pair<std::string, std::string>> calls_;
  std::string fail_addr_;
  std::string fail_after_addr_;
  size_t fail_after_ = 0;
};

class ChainClaimTest : public ::testing::Test {
 protected:
  ChainClaimTest() {
    ReshardService::Options options;
    options.port = 0;
    options.client = &transport_;
    options.clock = [this]() { return now_; };
    options.request_registry_ttl_s = kTtlS;
    service_ = std::make_unique<ReshardService>(options);
    RegisterUnits();
  }

  template <typename Req>
  tpu_sync::rpc::ControllerResponse HandleController(
      const Req& req) {
    tpu_sync::rpc::ControllerResponse resp;
    resp.ParseFromString(service_->HandleFrame(req.SerializeAsString()));
    return resp;
  }

  void RegisterUnits() {
    auto reg_unit = [&](const RaidenId& unit, const std::string& shard,
                        const std::string& ctrl, int parallelism, int rank,
                        int page_tokens) {
      tpu_sync::rpc::ControlRequest req;
      req.set_command(
          tpu_sync::rpc::ControlRequest::COMMAND_REGISTER_WORK_UNIT);
      auto* reg = req.mutable_register_work_unit_request();
      *reg->mutable_unit() = RaidenIdToProto(unit);
      reg->add_shards(shard);
      reg->set_control_plane_rpc_address(ctrl);
      *reg->add_pools() = FaPool();
      reg->set_layout_fingerprint("fp1");
      reg->set_page_tokens(page_tokens);
      reg->set_transfer_parallelism(parallelism);
      reg->set_transfer_rank(rank);
      tpu_sync::rpc::ControlResponse resp;
      resp.ParseFromString(service_->HandleFrame(req.SerializeAsString()));
      ASSERT_TRUE(resp.success()) << resp.message();
    };
    for (int rank = 0; rank < 2; ++rank) {
      reg_unit(Src(rank), absl::StrCat("10.0.0.1:", 9000 + rank),
               absl::StrCat("10.0.0.1:", 9100 + 2 * rank), 2, rank, 512);
    }
    reg_unit(Dst(), "10.0.0.2:9400", kDstCtrl, 2, 0, 4096);
  }

  // Rank r declares whole destination pages 2r and 2r+1 (v1 global spans
  // from its source blocks 3+2r and 4+2r).
  void RegisterTwoPagesPerRank(const std::string& req_id, int64_t uuid) {
    for (int rank = 0; rank < 2; ++rank) {
      tpu_sync::rpc::ControllerRequest req;
      req.set_command(
          tpu_sync::rpc::ControllerRequest::COMMAND_REGISTER_REQUEST_BLOCKS);
      auto* block_req = req.mutable_register_request_blocks_request();
      block_req->set_req_id(req_id);
      block_req->set_uuid(uuid);
      *block_req->mutable_unit() = RaidenIdToProto(Src(rank));
      auto* entry = block_req->add_pool_spans();
      entry->set_tag("fa");
      for (int i = 0; i < 2; ++i) {
        block_req->add_block_ids(3 + 2 * rank + i);
        entry->add_block_ids(3 + 2 * rank + i);
        auto* span = entry->add_spans();
        span->set_src_block_ordinal(i);
        span->set_src_offset_bytes(0);
        span->set_dst_block_index(0);
        span->set_dst_offset_bytes((2 * rank + i) * 1024);
        span->set_size_bytes(1024);
        span->set_count(1);
      }
      entry->set_declared_bytes(2048);
      entry->set_dst_space_version(1);
      tpu_sync::rpc::ControllerResponse resp = HandleController(req);
      ASSERT_TRUE(resp.success()) << resp.message();
    }
  }

  tpu_sync::rpc::ControllerResponse Coordinate(const std::string& req_id,
                                               int64_t uuid,
                                               std::vector<int64_t> window) {
    tpu_sync::rpc::ControllerRequest req;
    req.set_command(
        tpu_sync::rpc::ControllerRequest::COMMAND_COORDINATE_TRANSFER);
    auto* coord = req.mutable_coordinate_transfer_request();
    for (int rank = 0; rank < 2; ++rank) {
      *coord->add_src_units() = RaidenIdToProto(Src(rank));
    }
    *coord->add_dst_units() = RaidenIdToProto(Dst());
    coord->set_uuid(uuid);
    coord->set_is_sender(true);
    coord->set_dst_mem_type(tpu_sync::rpc::MEMORY_TYPE_HBM);
    coord->set_use_block_chunks(true);
    coord->set_req_id(req_id);
    for (int64_t block : {7, 8, 9, 10}) coord->add_dst_device_block_ids(block);
    coord->add_transfer_pool_tags("fa");
    for (int64_t w : window) coord->add_dst_window_blocks(w);
    return HandleController(req);
  }

  // The vote a producer rank's caller sends after its native send terminal.
  tpu_sync::rpc::ControllerResponse VoteComplete(const std::string& req_id,
                                                 int64_t uuid, int rank) {
    tpu_sync::rpc::ControllerRequest req;
    req.set_command(
        tpu_sync::rpc::ControllerRequest::COMMAND_COMPLETE_REQUEST_BLOCKS);
    auto* complete = req.mutable_complete_request_blocks_request();
    complete->set_req_id(req_id);
    complete->set_uuid(uuid);
    *complete->mutable_unit() = RaidenIdToProto(Src(rank));
    return HandleController(req);
  }

  int Status(const std::string& req_id, int64_t uuid) {
    tpu_sync::rpc::ControllerRequest req;
    req.set_command(
        tpu_sync::rpc::ControllerRequest::COMMAND_GET_REQUEST_BLOCK_STATUS);
    auto* key = req.mutable_get_request_block_status_request()->add_keys();
    key->set_req_id(req_id);
    key->set_uuid(uuid);
    tpu_sync::rpc::ControllerResponse resp = HandleController(req);
    EXPECT_TRUE(resp.success()) << resp.message();
    const auto& statuses = resp.get_request_block_status_response().statuses();
    return statuses.empty() ? -1 : statuses[0];
  }

  std::string CancelIfUnclaimed(const std::string& req_id, int64_t uuid) {
    tpu_sync::rpc::ControllerRequest req;
    req.set_command(tpu_sync::rpc::ControllerRequest::
                        COMMAND_CANCEL_REQUEST_BLOCKS_IF_UNCLAIMED);
    req.mutable_cancel_request_blocks_if_unclaimed_request()->set_req_id(
        req_id);
    req.mutable_cancel_request_blocks_if_unclaimed_request()->set_uuid(uuid);
    tpu_sync::rpc::ControllerResponse resp = HandleController(req);
    return resp.success() ? resp.response_data()
                          : absl::StrCat("error: ", resp.message());
  }

  std::string Name(int status) {
    return status < 0 ? "<none>"
                      : ProtoStatus::Status_Name(
                            static_cast<ProtoStatus::Status>(status));
  }

  std::string Calls() {
    absl::MutexLock lock(transport_.mu_);
    std::string out;
    for (const auto& [addr, payload] : transport_.calls_) {
      tpu_sync::rpc::ControlRequest req;
      req.ParseFromString(payload);
      const auto& st = req.start_transfer_request();
      absl::StrAppend(&out, out.empty() ? "" : ", ", addr,
                      st.is_sender() ? "(send" : "(arm", " sub_plan ",
                      st.sub_plan_index(), "/", st.sub_plan_count(), ")");
    }
    return out;
  }

  ArmRefusingTransport transport_;
  double now_ = 1000.0;
  std::unique_ptr<ReshardService> service_;
};

TEST_F(ChainClaimTest, ArmFailureAtSubPlan1LeavesClaimUntilTtl) {
  RegisterTwoPagesPerRank("req-1c", 81);
  transport_.fail_after_addr_ = kDstCtrl;
  transport_.fail_after_ = 1;  // sub-plan 0's arm accepted, sub-plan 1's not
  tpu_sync::rpc::ControllerResponse resp = Coordinate("req-1c", 81, {2});
  ASSERT_TRUE(resp.success()) << resp.message();
  service_->coordinator()->WaitForSubTransferChains();
  std::cerr << "[1C] worker calls: " << Calls() << "\n";
  std::cerr << "[1C] transfer status: "
            << static_cast<int>(
                   service_->coordinator()->GetTransferStatus("req-1c"))
            << " (4 = kFailed)\n";
  ASSERT_EQ(service_->coordinator()->GetTransferStatus("req-1c"),
            ReshardCoordinator::Status::kFailed);

  // Rank 0, the only dispatched sender, reaches its terminal and votes.
  tpu_sync::rpc::ControllerResponse vote0 = VoteComplete("req-1c", 81, 0);
  std::cerr << "[1C] rank 0 votes Complete -> success=" << vote0.success()
            << " rows_retired=" << vote0.response_data() << "\n";
  const int after_vote = Status("req-1c", 81);
  const std::string cancel = CancelIfUnclaimed("req-1c", 81);
  std::cerr << "[1C] after every dispatched sender voted: status="
            << Name(after_vote) << " CancelIfUnclaimed=" << cancel << "\n";
  EXPECT_NE(after_vote, ProtoStatus::STATUS_CLAIMED)
      << "the failed chain's claim outlives every dispatched sender's vote";
  EXPECT_EQ(cancel, "true")
      << "CancelIfUnclaimed still refuses after the chain failed and every "
         "dispatched sender voted";

  // Nothing else clears it before the TTL.
  now_ += kTtlS - 1.0;
  const int before_ttl = Status("req-1c", 81);
  std::cerr << "[1C] at claim+" << (kTtlS - 1.0)
            << "s: status=" << Name(before_ttl)
            << " CancelIfUnclaimed=" << CancelIfUnclaimed("req-1c", 81)
            << "\n";
  now_ += 2.0;
  const int after_ttl = Status("req-1c", 81);
  std::cerr << "[1C] at claim+" << (kTtlS + 1.0)
            << "s: status=" << Name(after_ttl) << "\n";
  EXPECT_NE(after_ttl, ProtoStatus::STATUS_CLAIMED) << "TTL clears it";
}

// Control: the undispatched rank's vote is the only thing missing -- had
// rank 1 voted too, the claim would retire at once.
TEST_F(ChainClaimTest, ControlUndispatchedRankVoteWouldRetireTheClaim) {
  RegisterTwoPagesPerRank("req-1c-ctl", 82);
  transport_.fail_after_addr_ = kDstCtrl;
  transport_.fail_after_ = 1;
  ASSERT_TRUE(Coordinate("req-1c-ctl", 82, {2}).success());
  service_->coordinator()->WaitForSubTransferChains();
  VoteComplete("req-1c-ctl", 82, 0);
  tpu_sync::rpc::ControllerResponse vote1 = VoteComplete("req-1c-ctl", 82, 1);
  const int status = Status("req-1c-ctl", 82);
  std::cerr << "[1C-ctl] rank 1 votes too -> rows_retired="
            << vote1.response_data() << " status=" << Name(status) << "\n";
  EXPECT_EQ(status, ProtoStatus::STATUS_UNKNOWN);
}

// Control: the same arm failure at sub-plan 0 abandons the claim at once.
TEST_F(ChainClaimTest, ControlArmFailureAtSubPlan0AbandonsTheClaim) {
  RegisterTwoPagesPerRank("req-1c-0", 83);
  transport_.fail_addr_ = kDstCtrl;
  tpu_sync::rpc::ControllerResponse resp = Coordinate("req-1c-0", 83, {2});
  const int status = Status("req-1c-0", 83);
  const std::string cancel = CancelIfUnclaimed("req-1c-0", 83);
  std::cerr << "[1C-0] coordinate success=" << resp.success() << " ("
            << resp.message() << "); worker calls: " << Calls()
            << "; status=" << Name(status) << " CancelIfUnclaimed=" << cancel
            << "\n";
  EXPECT_FALSE(resp.success());
  EXPECT_EQ(status, ProtoStatus::STATUS_REGISTERED);
  EXPECT_EQ(cancel, "true");
}

}  // namespace
}  // namespace reshard
}  // namespace kv_cache
}  // namespace tpu_raiden
