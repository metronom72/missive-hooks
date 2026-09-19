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

## Why the classifier reads a field instead of making a call

Labelling is `PATCH /v1/conversations/:id` rather than a post into the thread,
because the documentation offers that endpoint to "close, reopen, move,
assign, label, recolor, or rename conversations silently" — and a classifier
that announced itself in every thread would be a worse product decision than a
wrong label.

The same paragraph contains the sharp part: *"When the update changes shared
labels, label change rules still run."*

This service is driven by a `label_change` rule. So writing a label can wake it
again, with a genuinely new event — a different payload, therefore a different
delivery key, therefore invisible to the de-duplication above, which is doing
exactly its job by letting it through. Left alone that is a feedback loop, and
it ends at a rate limit or at the auto-disable threshold, whichever arrives
first. Neither ending is loud.

Closing it costs nothing, because the webhook payload already carries
`conversation.shared_labels`. The state we would be writing is in our hands
before we write it: if the label is already there, the work is done — by us a
moment ago, or by a person — and neither case wants a second write. A guard
that instead asked the API "does it have the label?" would add a request to
every event to avoid a request on a few.

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

## Proving it against a live account

Everything above is proven by the suite, which runs without an account. The one
thing a suite cannot prove is that Missive's own delivery reaches this consumer
and that the label lands — for that the service has to be on the public
internet, behind a real rule, with a real mailbox in front of it.

That check needs a Missive workspace, so it belongs to whoever owns the
account. The steps, in the order that fails fastest:

1. In Missive, create a rule of type **label change** and copy its *Signature
   secret* into `MISSIVE_SIGNATURE_SECRET`.
2. Create an API token (Settings → API) into `MISSIVE_API_TOKEN`, and put the
   shared label's id into `MISSIVE_LABEL_LABEL_CHANGE`. The id, not the name:
   the API takes ids, and a name that looks right would fail at the last step
   with a 404 that reads like a routing problem.
3. Expose the consumer and point the rule at it:

   ```bash
   bundle exec rackup -p 9292 &
   bundle exec sidekiq -r ./config.ru -q webhooks &
   ngrok http 9292            # paste the https URL into the rule, path /webhooks/missive
   ```

4. Apply any shared label to a conversation by hand.

What should happen, and what each failure means:

| Observed | Meaning |
|---|---|
| `200` with `{"status":"accepted"}`, label appears on the conversation | the whole chain works — this is the proof |
| `401` with `invalid signature` | the secret in `.env` is not the rule's secret |
| `200` with `{"status":"dropped","reason":"unparsable payload"}` | Missive sent a shape the parser does not know; the body is in the log, and this is deliberately not a `500` — see above |
| `200` with `{"status":"duplicate"}` | the same delivery arrived twice, which is the documented normal case, and the claim held |
| `accepted` but no label on the conversation | the request path did its job and the worker did not: the Sidekiq log has the API's answer — usually a token without access, or a label *name* where an id belongs |
| nothing in the inspector at all | the rule is pointed elsewhere, or ngrok restarted and handed out a new URL |

The rule wakes on its own write, and the guard for that loop is in
`app/workers/classify_conversation_worker.rb` — the conversation is skipped
when the label is already on it. Worth watching on the first live event: a loop
here would show up as the same conversation cycling in the Sidekiq log, not as
an error.

## Layout

```
app/webhook_app.rb                    the request path, and nothing else
app/workers/classify_conversation_worker.rb   everything kept off it
lib/missive/delivery_semantics.rb     the five documented facts
lib/missive/signature.rb              raw-bytes HMAC, constant-time compare
lib/missive/delivery_log.rb           SET NX claim on a derived delivery key
lib/missive/client.rb                 one API call, net/http, short timeouts
```

Checked on 2026-09-10 against
<https://missiveapp.com/docs/developers/webhooks> (delivery semantics) and
<https://missiveapp.com/docs/developers/rest-api/endpoints> (the conversations
endpoint and the label-change note).
