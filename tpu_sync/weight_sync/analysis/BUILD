# Copyright 2026 Google LLC.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("@rules_python//python:defs.bzl", "py_binary", "py_library", "py_test")

package(default_visibility = ["//visibility:public"])

py_library(
    name = "roofline_model",
    srcs = ["roofline_model.py"],
    visibility = ["//visibility:public"],
)

py_library(
    name = "sharding_parser",
    srcs = ["sharding_parser.py"],
    visibility = ["//visibility:public"],
    deps = [
        ":roofline_model",
    ],
)

py_test(
    name = "roofline_model_test",
    srcs = ["roofline_model_test.py"],
    deps = [
        ":roofline_model",
        ":sharding_parser",
        "@com_google_absl_py//absl/testing:absltest",
    ],
)

py_binary(
    name = "roofline_cli",
    srcs = ["roofline_cli.py"],
    deps = [
        ":roofline_model",
        "@com_google_absl_py//absl:app",
        "@com_google_absl_py//absl/flags",
    ],
)
