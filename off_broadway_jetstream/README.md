# OffBroadway.Jetstream

A [NATS JetStream](https://docs.nats.io/nats-concepts/jetstream) producer for
[Broadway](https://github.com/elixir-broadway/broadway), built on
[gnat](https://hex.pm/packages/gnat).

`OffBroadway.Jetstream.Producer` pulls messages from a durable pull consumer. Every
producer of a pipeline long-polls the same consumer, so JetStream spreads the messages
across all producers (and across nodes running the same pipeline). Messages are
acknowledged explicitly once Broadway is done with them.

## Installation

The package lives in a subdirectory of this repository. Add it to your dependencies:

```elixir
def deps do
  [
    {:off_broadway_jetstream,
     github: "elixir-broadway/broadway", sparse: "off_broadway_jetstream"}
  ]
end
```

It requires Elixir 1.16 or later.

## Connection

The producer uses a `Gnat` connection that you start yourself. Use
`Gnat.ConnectionSupervisor` so the connection is restarted under the same name when it
drops, and start it before the pipeline:

```elixir
children = [
  {Gnat.ConnectionSupervisor,
   %{name: :gnat, connection_settings: [%{host: "localhost", port: 4222}]}},
  MyBroadway
]

Supervisor.start_link(children, strategy: :one_for_one)
```

Then pass `connection_name: :gnat` to the producer.

## Creating the stream and consumer

The producer needs an existing stream and a durable pull consumer with
`ack_policy: :explicit`. Create them upfront with the [`nats` CLI](https://github.com/nats-io/natscli):

```shell
nats stream add ORDERS --subjects "orders.>" --defaults
nats consumer add ORDERS order-worker --pull --ack explicit --max-deliver 5 --defaults
```

Alternatively, pass the consumer definition as the `:consumer` option and the producer
creates it on connect when it does not exist yet:

```elixir
{OffBroadway.Jetstream.Producer,
 connection_name: :gnat,
 consumer: %Gnat.Jetstream.API.Consumer{
   stream_name: "ORDERS",
   durable_name: "order-worker",
   max_deliver: 5
 }}
```

## Pipeline example

```elixir
defmodule MyBroadway do
  use Broadway

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module:
          {OffBroadway.Jetstream.Producer,
           connection_name: :gnat,
           stream_name: "ORDERS",
           consumer_name: "order-worker"},
        concurrency: 2
      ],
      processors: [
        default: [concurrency: 10]
      ]
    )
  end

  @impl true
  def handle_message(_processor, message, _context) do
    IO.inspect(message.data, label: "Got message")
    message
  end
end
```

See the `OffBroadway.Jetstream.Producer` documentation for all options.

## Acknowledgements

The `:on_success` (default `:ack`) and `:on_failure` (default `:nack`) options set what
happens to a message once Broadway is done with it. Override them per message with
`Broadway.Message.configure_ack/2`.

| Action | Sent to JetStream | Effect |
| --- | --- | --- |
| `:ack` | empty body (`+ACK`) | The message is done and not redelivered. |
| `:nack` | `-NAK` | The message is redelivered right away, up to `max_deliver` (unlimited by default). |
| `{:nack, delay_ms}` | `-NAK {"delay": ns}` | The message is redelivered after `delay_ms`, up to `max_deliver`. |
| `:term` | `+TERM` | The message is not redelivered and not counted as processed. |
| `:noop` | nothing | The message is redelivered once the consumer's `ack_wait` elapses. |

### Redelivery and poison messages

- **`ack_wait`**: a message must be acknowledged within the consumer's `ack_wait`
  (30 seconds by default). The producer does not extend it, so a message still in a
  processor or batcher past `ack_wait` is delivered again while the first copy is still
  being handled. Set `ack_wait` above your longest handling time plus `batch_timeout`,
  and make handlers idempotent (for example keyed on
  `message.metadata.jetstream.stream_seq` or a publisher-set `Nats-Msg-Id` header).
- **`max_deliver`**: unlimited unless the consumer sets it. With the default
  `on_failure: :nack`, a message that always fails is redelivered immediately and
  forever. Always set `max_deliver`, and use `{:nack, delay_ms}` to space out retries.
  A plain `:nack` ignores the consumer's `backoff`, which only applies to messages left
  unacknowledged past `ack_wait`.
- **Dead letters**: JetStream has no dead-letter queue. When a message reaches
  `max_deliver`, the server publishes an advisory on
  `$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.<stream>.<consumer>` with the message's
  `stream_seq`. Subscribe to it and fetch the message with
  `Gnat.Jetstream.API.Stream.get_message/4`.

## Message metadata

Each message has the following metadata:

  * `:subject` - the subject the message was published to
  * `:headers` - the message headers as `{name, value}` tuples (`[]` when there are none)
  * `:reply_to` - the `$JS.ACK.…` subject used to acknowledge the message
  * `:jetstream` - a `Gnat.Jetstream.API.Message.Metadata` struct with the stream and
    consumer sequences, the delivery count, the number of pending messages and the
    timestamp

## Running the tests

The tests run against a real NATS server with JetStream enabled on `localhost:4222`:

```shell
docker run --rm -d -p 4222:4222 --name nats-js nats:2.15.2-alpine -js
mix test
```

## License

Apache License 2.0, the same as Broadway.
