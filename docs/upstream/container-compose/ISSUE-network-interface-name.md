# Compose compatibility gap: network interface name

## Compose surface

`services.<name>.networks.<network>.interface_name`

## Docker Compose V2 behavior

The Compose Specification preserves `interface_name` on a service network
attachment so the container can use a stable interface name rather than relying
on attachment order.

Reference: <https://docs.docker.com/reference/compose-file/services/#interface_name>

## Previous behavior

The normalizer preserved `interface_name`, but runtime validation rejected it
before resource creation because the matched Apple runtime had no guest-name
primitive.

## Ownership and minimal implementation

`container-compose` owns the narrow translation to the matched runtime command
vector. `apple/container` owns the typed attachment field;
`apple/containerization` owns guest-agent validation and rename. Compose does
not duplicate Linux name validation.

## Expected behavior

- `config --format json` retains the normalizer's `interfaceName` value.
- `up`, `create`, and one-off `run` render `--network NAME,interface=VALUE`.
- Commas fail before Compose renders its delimiter-based runtime attachment;
  other invalid guest interface names fail at the generic runtime boundary.
