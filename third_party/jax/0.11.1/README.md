# JAX 0.11.1

- JAX commit: `2d66622450e2c8633cda2307688ef7aa294bd6eb`
- XLA commit: `dcf304bc5dca1932b99f740b911dbd73631a1a69`
- rules_ml_toolchain: `73cb731fed3ccf7551beac710bf1c5dbeb8be298`
- abseil-cpp: `20260526.0`
- libtpu: `0.0.46.1`
- `RAIDEN_JAX`: `1101`

## Patches
- `patches/py/jax_remove_local_wheels.patch`: Custom patch for JAX 0.11.1 wheel dependencies.
- `patches/rules_ml_toolchain/no_register_toolchains.patch`: Removes duplicate toolchain registration.
