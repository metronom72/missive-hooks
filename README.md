# missive-hooks

A webhook consumer for the [Missive](https://missiveapp.com) API, built around
the platform's delivery semantics rather than in spite of them.

The interesting part of a webhook consumer is not the endpoint. It is what the
sender promises and what it does not, and how much of that ends up encoded in
the shape of the service instead of in a comment nobody reads. Missive
documents five things:

| Fact | Documented as | What it decides here |
|---|---|---|
| Signature header | `X-Hook-Signature` | verification over raw bytes, constant-time compare |
| Signature format | `sha256=` + HMAC **hexdigest** | not Base64 — the prefix is part of the compared value |
| Response budget | "respond within 15 seconds" | acknowledge first, work later |
| Retries | "up to 5 times over a period of 8 minutes" | duplicate delivery is the normal case |
| Auto-disable | "fails **more than 50 times** in a row" | a payload we cannot read is dropped, not 500'd |

All five live in one file, [`lib/missive/delivery_semantics.rb`](lib/missive/delivery_semantics.rb),
each next to the sentence it came from, and
[`spec/delivery_semantics_spec.rb`](spec/delivery_semantics_spec.rb) is a
tripwire on them: this README quotes those numbers, so a silent edit would
leave the prose lying about the code.

## Why the acknowledgement comes before the work

The response budget is fifteen seconds. That number is easy to read as "be
reasonably quick" and it is not that. It is a statement about who owns the
worst case.

Classifying a conversation means calling the Missive API. That call has a
latency distribution belonging to somebody else's service, and its tail is not
mine to bound — no timeout I choose makes their p99 my p99, it only decides how
I fail when theirs is bad. If that call sits on the request path, then every
slow afternoon on their side becomes a delivery that times out on mine. And a
timeout is not a neutral outcome: it counts as a failure, failures accumulate,
and more than fifty in a row switch the rule off. The integration does not
degrade. It stops, quietly, while the endpoint still answers `/healthz` and
every dashboard stays green.

So the request path does four things that are all bounded by local work:
verify the signature, parse, claim the delivery, enqueue. Then it answers. The
API call happens in a Sidekiq worker, where a slow response costs a retry
instead of the rule's health, and where the retry is *mine* — Missive has
already been told the delivery was accepted and must never redeliver it on my
account.

The test for this does not measure time, because a fast test proves nothing
about a slow API. It asserts that no outbound HTTP request is made while
answering; WebMock fails the example if one is.

## Why de-duplication is structural

Five retries over eight minutes is not an error budget. It means that for any
delivery that is worth retrying, the same event arrives more than once by
design, and a consumer that treats the second arrival as an anomaly will label
a conversation twice on an ordinary Tuesday.

Missive does not send a delivery id, so the key is derived: the SHA-256 of the
raw body. A retry re-sends the same bytes, so the digest is stable across all
five attempts; two genuinely different events differ somewhere in the payload —
at minimum in the conversation id — so they hash apart. Both properties are
tested.

The claim is a single `SET NX EX`, not a read followed by a write. The retry
schedule promises when Missive gives up, not that attempts are serialised; two
retries can be in flight at once, and a read-then-write pair lets both of them
believe they are first. The TTL is a day — comfortably longer than the eight
minute window, because a key that expires inside the retry window readmits the
exact duplicate it exists to stop.

## Why a malformed payload gets a 200

This is the decision that looks wrong and is not.

A body we cannot parse is a bug, and the instinct is to answer 500 so it shows
up as one. But a payload shape we do not handle is almost never a single event;
it is a whole class of them, and every member of that class will fail the same
way. More than fifty consecutive failures disable the rule. So the honest 500
buys a red line on a graph and pays for it by turning the integration off —
and the fix is on my side either way, because Missive did nothing wrong by
sending it.

So: acknowledge, drop, log loudly. The failure is visible where it should be
visible — in my logs, in my alerting — and invisible where it would do damage,
in the rule's failure streak.

One case is refused outright. A request with a wrong signature, or no signature
at all, is answered `401`, because it did not come from Missive: it is not a
delivery, so it cannot count toward anybody's failure streak, and treating an
unsigned request as acceptable would make this an open endpoint.

## Running it

```bash
bundle install
cp .env.example .env      # MISSIVE_SIGNATURE_SECRET is required, no default
redis-server &
bundle exec rackup -p 9292
bundle exec sidekiq -r ./config.ru -q webhooks
```

```bash
bundle exec rspec
```

The service refuses to boot without `MISSIVE_SIGNATURE_SECRET`. A webhook
consumer that cannot verify signatures is not a degraded service, it is an open
endpoint, and defaulting it to empty would make the failure silent.

## Layout

```
app/webhook_app.rb                    the request path, and nothing else
app/workers/classify_conversation_worker.rb   everything kept off it
lib/missive/delivery_semantics.rb     the five documented facts
lib/missive/signature.rb              raw-bytes HMAC, constant-time compare
lib/missive/delivery_log.rb           SET NX claim on a derived delivery key
lib/missive/client.rb                 one API call, net/http, short timeouts
```

Semantics checked against
<https://missiveapp.com/docs/developers/webhooks> on 2026-09-10.
