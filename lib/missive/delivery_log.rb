# frozen_string_literal: true

require 'digest'
require 'time'
require_relative 'delivery_semantics'

module Missive
  # Remembers which deliveries have already been accepted.
  #
  # Missive does not send a delivery id, so the key is derived: the SHA-256 of
  # the raw body. A retry re-sends the same bytes, so the digest is stable
  # across the five attempts; two genuinely different events differ somewhere
  # in the payload -- at minimum in the conversation id -- so they hash apart.
  #
  # The check and the claim are one operation (SET NX), not "read, decide,
  # write". Two retries can arrive concurrently -- the retry schedule is a
  # promise about when Missive gives up, not about serialisation -- and a
  # read-then-write pair lets both of them win.
  class DeliveryLog
    KEY_PREFIX = 'missive-hooks:delivery:'

    def initialize(redis, ttl: DeliverySemantics::DELIVERY_KEY_TTL_SECONDS)
      @redis = redis
      @ttl = ttl
    end

    # @return [String] the delivery key for these bytes
    def self.key_for(raw_body)
      Digest::SHA256.hexdigest(raw_body)
    end

    # Claims the delivery for processing.
    #
    # @return [Boolean] true the first time these bytes are seen, false for
    #   every retry of the same delivery
    def claim(delivery_key)
      @redis.set(KEY_PREFIX + delivery_key, Time.now.utc.iso8601, nx: true, ex: @ttl) ? true : false
    end

    def seen?(delivery_key)
      @redis.exists?(KEY_PREFIX + delivery_key)
    end
  end
end
