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

"""Document and markdown parser for model weight structures and sharding specifications."""

import dataclasses
import math
import re

from tpu_sync.weight_sync.analysis import roofline_model

ModelSpec = roofline_model.ModelSpec


@dataclasses.dataclass(frozen=True)
class TensorEntry:
  """A single tensor variable entry extracted from specifications.

  Attributes:
    component: Subsystem or layer component description.
    key: Parameter identifier key path.
    shape: Tuple of dimension extents.
    dtype: Data type string representation.
    train_sharding: Sharding mesh specification for training.
    infer_sharding: Sharding mesh specification for inference.
    layer_count: Layer replication multiplicity count.
  """

  component: str
  key: str
  shape: tuple[int, ...]
  dtype: str
  train_sharding: str
  infer_sharding: str
  layer_count: int = 1

  @property
  def num_elements(self) -> int:
    """Computes total elements across all layers."""
    return math.prod(self.shape) * self.layer_count

  @property
  def byte_size(self) -> int:
    """Computes aggregate byte size across all elements and layers.

    Returns:
      Total byte size as an integer.

    Raises:
      ValueError: If dtype is unrecognized.
    """
    clean_dtype = self.dtype.lower().strip()
    if clean_dtype in {"bfloat16", "float16", "fp16", "bf16"}:
      bytes_per_elem = 2
    elif clean_dtype in {
        "fp8",
        "int8",
        "uint8",
        "float8",
        "float8_e4m3fn",
        "float8_e5m2",
    }:
      bytes_per_elem = 1
    elif clean_dtype in {"float32", "fp32", "int32"}:
      bytes_per_elem = 4
    else:
      raise ValueError(
          f"Unsupported dtype '{self.dtype}' for tensor '{self.key}'."
      )
    return self.num_elements * bytes_per_elem


class ShardingDocParser:
  """Parses Google Doc or Markdown weight structure and sharding tables."""

  @classmethod
  def parse_markdown_table(
      cls,
      markdown_text: str,
      model_name: str = "ParsedModel",
      num_layers: int = 60,
  ) -> ModelSpec:
    """Extracts tensor entries from a markdown table and computes model specs.

    Args:
      markdown_text: Markdown text containing the sharding table.
      model_name: Designated name for the constructed ModelSpec.
      num_layers: Total layer count for the architecture.

    Returns:
      Constructed ModelSpec reflecting aggregated weights and layers.

    Raises:
      ValueError: If a row has malformed dimensions or if no entries are found.
    """
    lines = markdown_text.splitlines()
    entries: list[TensorEntry] = []

    # Regex to extract table row columns
    row_regex = re.compile(
        r"^\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*\[(.*?)\]\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|$"
    )

    for line in lines:
      match = row_regex.match(line.strip())
      if not match:
        continue
      comp, key, shape_str, dtype, train_sh, infer_sh = match.groups()
      if "Component" in comp or "---" in comp:
        continue

      # Parse shape dimensions
      try:
        shape = tuple(int(x.strip()) for x in shape_str.split(",") if x.strip())
      except ValueError as err:
        raise ValueError(
            f"Malformed shape '{shape_str}' in line: {line!r}"
        ) from err

      # Parse layer count from component name if present (e.g. "(45 layers)")
      layer_count = 1
      layer_match = re.search(r"\((\d+)\s+layers?\)", comp, re.IGNORECASE)
      all_layers_match = re.search(r"all\s+(\d+)\s+layers", comp, re.IGNORECASE)
      if layer_match:
        layer_count = int(layer_match.group(1))
      elif all_layers_match:
        layer_count = int(all_layers_match.group(1))
      elif "all layers" in comp.lower():
        layer_count = num_layers

      entries.append(
          TensorEntry(
              component=comp,
              key=key,
              shape=shape,
              dtype=dtype,
              train_sharding=train_sh,
              infer_sharding=infer_sh,
              layer_count=layer_count,
          )
      )

    if not entries:
      raise ValueError("No valid tensor entries found in markdown table.")

    total_params = sum(e.num_elements for e in entries)
    total_bytes = sum(e.byte_size for e in entries)
    num_vars = len(entries)

    return ModelSpec(
        name=model_name,
        total_params=total_params,
        dtype_bytes=2,
        total_bytes=float(total_bytes),
        num_layers=num_layers,
        num_variables=num_vars,
    )
