# frozen_string_literal: true

require 'json'
require 'sinatra/base'

require_relative '../lib/missive/delivery_semantics'
require_relative '../lib/missive/signature'
require_relative '../lib/missive/delivery_log'
require_relative 'workers/classify_conversation_worker'

module Missive
  # The HTTP surface: one endpoint, and as little of it as possible.
  #
  # Everything here is written against a 15 second response budget. The rule is
  # not "be fast"; it is that no call whose worst case belongs to somebody else
  # may sit on the request path. Verify, de-duplicate, enqueue, answer.
  class WebhookApp < Sinatra::Base
    set :logging, true
    set :show_exceptions, false
    set :raise_errors, false

    post '/webhooks/missive' do
      raw = request.body.read
      request.body.rewind

      unless Signature.valid?(raw, settings.signature_secret, request.env['HTTP_X_HOOK_SIGNATURE'])
        # An unsigned or wrongly signed request did not come from Missive, so
        # it is not a delivery and cannot count toward a failure streak of
        # theirs. This is the one case that is refused outright.
        logger.warn('rejected: signature mismatch')
        halt 401, json_body(error: 'invalid signature')
      end

      payload = parse(raw)
      if payload.nil?
        # Acknowledged and dropped, on purpose.
        #
        # A 500 here would be honest about our confusion and wrong about the
        # consequence: a payload shape we cannot read is usually a whole class
        # of events, every one of which would fail, and more than fifty
        # failures in a row disables the rule. The integration would go quiet
        # while every dashboard still showed a healthy endpoint. Dropping is
        # visible in our logs and invisible to the rule's health -- which is
        # the correct trade, because the fix is on our side either way.
        logger.warn("dropped: unparsable payload (#{raw.bytesize} bytes)")
        return json_body(status: 'dropped', reason: 'unparsable payload')
      end

      delivery_key = DeliveryLog.key_for(raw)
      unless settings.delivery_log.claim(delivery_key)
        # Not an error and not a warning. Five retries over eight minutes make
        # this the expected path, not the sad one.
        logger.info("duplicate: #{delivery_key[0, 12]}")
        return json_body(status: 'duplicate', delivery: delivery_key)
      end

      ClassifyConversationWorker.perform_async(delivery_key, payload)
      json_body(status: 'accepted', delivery: delivery_key)
    end

    get '/healthz' do
      json_body(status: 'ok')
    end

    error do
      # Even an unexpected failure answers 200 once the delivery is ours to
      # handle: by this point the work is queued or the payload is dropped, and
      # a 500 would only push the rule toward auto-disable for a bug of ours.
      logger.error("unhandled: #{env['sinatra.error']&.message}")
      json_body(status: 'error-logged')
    end

    private

    def parse(raw)
      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) && parsed.key?('rule') ? parsed : nil
    rescue JSON::ParserError
      nil
    end

    def json_body(**attrs)
      content_type :json
      JSON.generate(attrs)
    end
  end
end
