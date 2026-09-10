# frozen_string_literal: true

module Missive
  # The platform's delivery contract, in one place.
  #
  # These five facts are not configuration and not folklore. Each is quoted
  # from https://missiveapp.com/docs/developers/webhooks (checked 2026-09-10),
  # and each one decides something about the shape of this service. They are
  # gathered here so that a reader can see the whole contract at once, and so
  # that a change on Missive's side lands in one file instead of five.
  module DeliverySemantics
    # "X-Hook-Signature hash signature of the payload."
    SIGNATURE_HEADER = 'X-Hook-Signature'

    # "The signature starts with sha256= followed by a HMAC hexdigest."
    #
    # Hexdigest, not Base64. The prefix is part of the header value, so it is
    # part of what gets compared.
    SIGNATURE_PREFIX = 'sha256='
    SIGNATURE_DIGEST = 'sha256'

    # "The endpoint must accept POST requests and respond within 15 seconds."
    #
    # This is the whole reason the request handler acknowledges before it
    # works. Anything that talks to another service -- the Missive API
    # included -- cannot be on the request path, because its worst case is not
    # ours to bound.
    RESPONSE_BUDGET_SECONDS = 15

    # "the request will be retried up to 5 times over a period of 8 minutes"
    #
    # Five retries make duplicate delivery the normal case rather than an
    # anomaly, which is why de-duplication here is structural and not a
    # defensive afterthought.
    MAX_RETRIES = 5
    RETRY_WINDOW_SECONDS = 8 * 60

    # "If a webhook rule fails more than 50 times in a row, the rule will be
    # automatically disabled."
    #
    # More than fifty, not fifty. The number matters less than the direction:
    # a failure streak is silent until the integration is simply off. That is
    # why a payload we cannot parse is acknowledged and dropped instead of
    # answered with a 500 -- one unhandled event class must not be able to
    # walk the rule toward this limit.
    AUTO_DISABLE_AFTER_CONSECUTIVE_FAILURES = 50

    # How long a delivery key is remembered. Comfortably longer than the retry
    # window: the point of the key is to survive every retry of the same
    # delivery, and a day of Redis keys is cheaper than one duplicated label.
    DELIVERY_KEY_TTL_SECONDS = 24 * 60 * 60
  end
end
