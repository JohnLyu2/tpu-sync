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

#include "tpu_sync/transport/lib/transport_metrics_exporter.h"

#include <cstdint>
#include <memory>
#include <utility>

#include <gmock/gmock.h>
#include <gtest/gtest.h>
#include "peregrine/src/api/transport_metrics.h"
#include "tpu_sync/telemetry/metrics_backend.h"
#include "tpu_sync/telemetry/mock_metrics_backend.h"

namespace tpu_raiden::transport::lib {
namespace {

namespace metric_labels = ::tpu_raiden::telemetry::metric_labels;
namespace metric_names = ::tpu_raiden::telemetry::metric_names;
using ::testing::_;
using ::testing::DoubleEq;
using ::testing::ElementsAre;
using ::testing::NiceMock;
using ::tpu_raiden::telemetry::MetricLabel;
using ::tpu_raiden::telemetry::MockMetricsBackend;
using ::tpu_raiden::telemetry::ScopedMetricsBackendReset;

constexpr MetricLabel kWriteLabel{.key = metric_labels::kDirection,
                                  .value = metric_labels::kDirectionWrite};
constexpr MetricLabel kReadLabel{.key = metric_labels::kDirection,
                                 .value = metric_labels::kDirectionRead};

TEST(TransportMetricsExporterTest,
     FastPathExitWhenNoBackendsStillUpdatesBaseline) {
  ScopedMetricsBackendReset reset_empty(nullptr);
  TransportMetricsExporter exporter;

  peregrine::TransportMetrics m1{};
  m1.write.bytes = 1024;
  m1.write.errors = 2;
  m1.write.e2e_latency_us.buckets[0] = 3;

  // Export with no backends registered; should update prev_metrics_ to m1.
  exporter.Export(m1);

  auto mock_backend = std::make_unique<MockMetricsBackend>();
  MockMetricsBackend* mock = mock_backend.get();
  ScopedMetricsBackendReset reset(std::move(mock_backend));

  peregrine::TransportMetrics m2 = m1;
  m2.write.bytes = 1524;  // delta = 500

  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineBytesTotal,
                                      ElementsAre(kWriteLabel), 500))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(_, _, _)).Times(0);

  exporter.Export(m2);
}

TEST(TransportMetricsExporterTest,
     ExportsWriteAndReadCounterAndHistogramDeltas) {
  auto mock_backend = std::make_unique<MockMetricsBackend>();
  MockMetricsBackend* mock = mock_backend.get();
  ScopedMetricsBackendReset reset(std::move(mock_backend));
  TransportMetricsExporter exporter;

  peregrine::TransportMetrics m1{};
  m1.write.bytes = 4096;
  m1.write.errors = 1;
  m1.write.e2e_latency_us.buckets[0] = 2;      // bucket 0 -> 0.0
  m1.write.e2e_latency_us.buckets[4] = 1;      // bucket 4 -> 2^(4-1) = 8.0
  m1.write.request_size_bytes.buckets[1] = 1;  // bucket 1 -> 2^(1-1) = 1.0
  m1.read.bytes = 8192;
  m1.read.errors = 3;
  m1.read.e2e_latency_us.buckets[10] = 2;      // bucket 10 -> 2^9 = 512.0
  m1.read.request_size_bytes.buckets[31] = 1;  // bucket 31 -> 2^30

  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineBytesTotal,
                                      ElementsAre(kWriteLabel), 4096))
      .Times(1);
  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineErrorsTotal,
                                      ElementsAre(kWriteLabel), 1))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineE2eLatencyUs,
                                      ElementsAre(kWriteLabel), DoubleEq(0.0)))
      .Times(2);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineE2eLatencyUs,
                                      ElementsAre(kWriteLabel), DoubleEq(8.0)))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineRequestSizeBytes,
                                      ElementsAre(kWriteLabel), DoubleEq(1.0)))
      .Times(1);

  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineBytesTotal,
                                      ElementsAre(kReadLabel), 8192))
      .Times(1);
  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineErrorsTotal,
                                      ElementsAre(kReadLabel), 3))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineE2eLatencyUs,
                                      ElementsAre(kReadLabel), DoubleEq(512.0)))
      .Times(2);
  EXPECT_CALL(
      *mock, ObserveHistogram(metric_names::kPeregrineRequestSizeBytes,
                              ElementsAre(kReadLabel),
                              DoubleEq(static_cast<double>(uint64_t{1} << 30))))
      .Times(1);

  exporter.Export(m1);
}

TEST(TransportMetricsExporterTest, IdenticalSnapshotEmitsNoDeltas) {
  ScopedMetricsBackendReset setup_reset(
      std::make_unique<NiceMock<MockMetricsBackend>>());
  TransportMetricsExporter exporter;

  peregrine::TransportMetrics m1{};
  m1.write.bytes = 4096;
  m1.write.errors = 1;
  m1.write.e2e_latency_us.buckets[0] = 2;
  m1.read.bytes = 8192;
  m1.read.errors = 3;
  m1.read.request_size_bytes.buckets[5] = 1;
  exporter.Export(m1);

  auto mock_backend = std::make_unique<MockMetricsBackend>();
  MockMetricsBackend* mock = mock_backend.get();
  ScopedMetricsBackendReset reset(std::move(mock_backend));

  EXPECT_CALL(*mock, IncrementCounter(_, _, _)).Times(0);
  EXPECT_CALL(*mock, ObserveHistogram(_, _, _)).Times(0);
  exporter.Export(m1);
}

TEST(TransportMetricsExporterTest,
     ExportsIncrementalCounterAndHistogramDeltas) {
  ScopedMetricsBackendReset setup_reset(
      std::make_unique<NiceMock<MockMetricsBackend>>());
  TransportMetricsExporter exporter;

  peregrine::TransportMetrics m1{};
  m1.write.bytes = 4096;
  m1.write.e2e_latency_us.buckets[4] = 1;
  exporter.Export(m1);

  auto mock_backend = std::make_unique<MockMetricsBackend>();
  MockMetricsBackend* mock = mock_backend.get();
  ScopedMetricsBackendReset reset(std::move(mock_backend));

  peregrine::TransportMetrics m2 = m1;
  m2.write.bytes += 1024;
  m2.write.e2e_latency_us.buckets[4] += 3;

  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineBytesTotal,
                                      ElementsAre(kWriteLabel), 1024))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineE2eLatencyUs,
                                      ElementsAre(kWriteLabel), DoubleEq(8.0)))
      .Times(3);

  exporter.Export(m2);
}

TEST(TransportMetricsExporterTest, HandlesUint64WrapAroundCorrectly) {
  ScopedMetricsBackendReset setup_reset(
      std::make_unique<NiceMock<MockMetricsBackend>>());
  TransportMetricsExporter exporter;

  peregrine::TransportMetrics m1{};
  m1.write.bytes = UINT64_MAX - 1;
  m1.write.e2e_latency_us.buckets[2] = UINT64_MAX - 3;
  exporter.Export(m1);

  auto mock_backend = std::make_unique<MockMetricsBackend>();
  MockMetricsBackend* mock = mock_backend.get();
  ScopedMetricsBackendReset reset(std::move(mock_backend));

  // m2 wraps around uint64
  peregrine::TransportMetrics m2 = m1;
  m2.write.bytes = 5;                      // delta = 5 - (2^64 - 2) = 7
  m2.write.e2e_latency_us.buckets[2] = 2;  // delta = 2 - (2^64 - 4) = 6

  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineBytesTotal,
                                      ElementsAre(kWriteLabel), 7))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineE2eLatencyUs,
                                      ElementsAre(kWriteLabel), DoubleEq(2.0)))
      .Times(6);

  exporter.Export(m2);
}

TEST(TransportMetricsExporterTest,
     IgnoresCounterAndHistogramDecreasesOrResets) {
  ScopedMetricsBackendReset setup_reset(
      std::make_unique<NiceMock<MockMetricsBackend>>());
  TransportMetricsExporter exporter;

  peregrine::TransportMetrics m1{};
  m1.write.bytes = 10000;
  m1.write.errors = 10;
  m1.write.e2e_latency_us.buckets[3] = 50;
  m1.write.e2e_latency_us.buckets[5] = 20;
  m1.write.request_size_bytes.buckets[4] = 30;
  m1.read.bytes = 20000;
  m1.read.errors = 8;
  m1.read.e2e_latency_us.buckets[2] = 40;
  m1.read.e2e_latency_us.buckets[6] = 15;
  m1.read.request_size_bytes.buckets[8] = 25;
  exporter.Export(m1);

  auto mock_backend = std::make_unique<MockMetricsBackend>();
  MockMetricsBackend* mock = mock_backend.get();
  ScopedMetricsBackendReset reset(std::move(mock_backend));

  // m2 decreases / resets across write and read metrics, errors,
  // request_size_bytes, and multi-bucket histograms (m2.Count() < m1.Count()).
  peregrine::TransportMetrics m2 = m1;
  m2.write.bytes = 500;
  m2.write.errors = 2;
  m2.write.e2e_latency_us.buckets[3] = 0;
  m2.write.e2e_latency_us.buckets[5] = 5;
  m2.write.request_size_bytes.buckets[4] = 3;
  m2.read.bytes = 1000;
  m2.read.errors = 1;
  m2.read.e2e_latency_us.buckets[2] = 5;
  m2.read.e2e_latency_us.buckets[6] = 0;
  m2.read.request_size_bytes.buckets[8] = 4;
  ASSERT_LT(m2.write.e2e_latency_us.Count(), m1.write.e2e_latency_us.Count());
  ASSERT_LT(m2.read.e2e_latency_us.Count(), m1.read.e2e_latency_us.Count());

  EXPECT_CALL(*mock, IncrementCounter(_, _, _)).Times(0);
  EXPECT_CALL(*mock, ObserveHistogram(_, _, _)).Times(0);
  exporter.Export(m2);
}

TEST(TransportMetricsExporterTest,
     ExportsDeltasFromNewBaselineAfterCounterAndHistogramReset) {
  ScopedMetricsBackendReset setup_reset(
      std::make_unique<NiceMock<MockMetricsBackend>>());
  TransportMetricsExporter exporter;

  peregrine::TransportMetrics m1{};
  m1.write.bytes = 10000;
  m1.write.errors = 10;
  m1.write.e2e_latency_us.buckets[3] = 50;
  m1.write.e2e_latency_us.buckets[5] = 20;
  m1.write.request_size_bytes.buckets[4] = 30;
  m1.read.bytes = 20000;
  m1.read.errors = 8;
  m1.read.e2e_latency_us.buckets[2] = 40;
  m1.read.request_size_bytes.buckets[8] = 25;
  exporter.Export(m1);

  // Reset to lower baseline m2 (multi-bucket histogram where bucket 3 resets to
  // 0 while bucket 5 has a non-zero count 5 after reset).
  peregrine::TransportMetrics m2{};
  m2.write.bytes = 500;
  m2.write.errors = 2;
  m2.write.e2e_latency_us.buckets[3] = 0;
  m2.write.e2e_latency_us.buckets[5] = 5;
  m2.write.request_size_bytes.buckets[4] = 3;
  m2.read.bytes = 1000;
  m2.read.errors = 1;
  m2.read.e2e_latency_us.buckets[2] = 5;
  m2.read.request_size_bytes.buckets[8] = 4;
  ASSERT_LT(m2.write.e2e_latency_us.Count(), m1.write.e2e_latency_us.Count());
  exporter.Export(m2);

  auto mock_backend = std::make_unique<MockMetricsBackend>();
  MockMetricsBackend* mock = mock_backend.get();
  ScopedMetricsBackendReset reset(std::move(mock_backend));

  // Subsequent forward increments from m2 are diffed against post-reset m2
  // rather than pre-reset m1.
  peregrine::TransportMetrics m3 = m2;
  m3.write.bytes = 650;                        // delta = 150
  m3.write.errors = 4;                         // delta = 2
  m3.write.e2e_latency_us.buckets[3] = 2;      // delta = 2 (val = 4.0)
  m3.write.e2e_latency_us.buckets[5] = 8;      // delta = 3 (val = 16.0)
  m3.write.request_size_bytes.buckets[4] = 5;  // delta = 2 (val = 8.0)
  m3.read.bytes = 1250;                        // delta = 250
  m3.read.errors = 3;                          // delta = 2
  m3.read.e2e_latency_us.buckets[2] = 6;       // delta = 1 (val = 2.0)
  m3.read.request_size_bytes.buckets[8] = 7;   // delta = 3 (val = 128.0)

  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineBytesTotal,
                                      ElementsAre(kWriteLabel), 150))
      .Times(1);
  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineErrorsTotal,
                                      ElementsAre(kWriteLabel), 2))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineE2eLatencyUs,
                                      ElementsAre(kWriteLabel), DoubleEq(4.0)))
      .Times(2);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineE2eLatencyUs,
                                      ElementsAre(kWriteLabel), DoubleEq(16.0)))
      .Times(3);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineRequestSizeBytes,
                                      ElementsAre(kWriteLabel), DoubleEq(8.0)))
      .Times(2);

  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineBytesTotal,
                                      ElementsAre(kReadLabel), 250))
      .Times(1);
  EXPECT_CALL(*mock, IncrementCounter(metric_names::kPeregrineErrorsTotal,
                                      ElementsAre(kReadLabel), 2))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineE2eLatencyUs,
                                      ElementsAre(kReadLabel), DoubleEq(2.0)))
      .Times(1);
  EXPECT_CALL(*mock, ObserveHistogram(metric_names::kPeregrineRequestSizeBytes,
                                      ElementsAre(kReadLabel), DoubleEq(128.0)))
      .Times(3);

  exporter.Export(m3);
}

}  // namespace
}  // namespace tpu_raiden::transport::lib
