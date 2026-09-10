# frozen_string_literal: true

require 'sidekiq'

require_relative '../../lib/missive/client'

module Missive
  # The slow half: everything that was deliberately kept off the request path.
  #
  # Retries here are Sidekiq's, not Missive's, and the two must not be
  # confused. Missive has already been told the delivery was accepted; if the
  # API call fails, that is ours to retry and never theirs to redeliver.
  class ClassifyConversationWorker
    include Sidekiq::Job

    sidekiq_options retry: 5, queue: 'webhooks'

    def perform(delivery_key, payload)
      conversation = payload['conversation'] or return
      label_id = label_for(payload)
      return if label_id.nil?

      Client.new.add_label(conversation_id: conversation['id'], label_id: label_id)
      logger.info("labelled #{conversation['id']} as #{label_id} (delivery #{delivery_key[0, 12]})")
    end

    private

    # Deliberately dull: the interesting part of this project is the delivery
    # contract, not the classifier. A rule's own type is the honest signal --
    # Missive already decided what happened, and second-guessing it in code
    # would be inventing a problem to look clever about.
    def label_for(payload)
      key = payload.dig('rule', 'type')
      ENV.fetch("MISSIVE_LABEL_#{key.to_s.upcase}", nil)
    end
  end
end
