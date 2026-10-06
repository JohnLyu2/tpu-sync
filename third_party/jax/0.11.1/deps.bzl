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

"""Dependency revisions for jax 0.11.1."""

DEPS = {
    "jax_version": "0.11.1",
    "jaxlib_version": "0.11.1",
    "raiden_jax": 1101,
    "jax_repo": "https://github.com/jax-ml/jax",
    "jax_commit": "2d66622450e2c8633cda2307688ef7aa294bd6eb",
    "jax_patches": [
        "third_party/jax/0.11.1/patches/py/jax_remove_local_wheels.patch",
    ],
    "xla_repo": "https://github.com/openxla/xla",
    "xla_commit": "dcf304bc5dca1932b99f740b911dbd73631a1a69",
    "xla_integrity": "sha256-TIns//WmYqbt+04tQD/t9VvkCjoAeePC+LpHs3wW6qs=",
    "xla_patches": [
        "third_party/xla/future_sfinae.patch",
        "third_party/xla/attribute_map_static_assert.patch",
        "third_party/xla/attribute_map_cc_static_assert.patch",
    ],
    "rules_ml_toolchain_repo": "https://github.com/google-ml-infra/rules_ml_toolchain",
    "rules_ml_toolchain_commit": "73cb731fed3ccf7551beac710bf1c5dbeb8be298",
    "rules_ml_toolchain_integrity": "sha256-dcy3xNxpk0PwLQLwtbqm2sCcAT1GuStg8YVjRI6lnnc=",
    "rules_ml_toolchain_patches": [
        "third_party/jax/0.11.1/patches/rules_ml_toolchain/no_register_toolchains.patch",
    ],
    "absl_repo": "https://github.com/abseil/abseil-cpp",
    "absl_version": "20260526.0",
    "absl_patches": [],
    "libtpu_version": "0.0.46.1",
}
