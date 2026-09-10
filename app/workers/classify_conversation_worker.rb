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

      # The loop guard, and the reason it is free.
      #
      # The documentation says of the conversations endpoint: "When the update
      # changes shared labels, label change rules still run." Our own webhook
      # is driven by a label_change rule, so writing a label can wake us again
      # with a fresh event -- a different payload, therefore a different
      # delivery key, therefore invisible to de-duplication. Left alone that is
      # a feedback loop that ends at the auto-disable limit or at a rate limit,
      # whichever arrives first.
      #
      # No extra request is needed to close it: the webhook payload already
      # carries conversation.shared_labels, so the state we would be writing is
      # in our hands. If the label is there, the work is done -- by us a moment
      # ago, or by a human, and neither case wants a second write.
      if already_labelled?(conversation, label_id)
        logger.info("skipped #{conversation['id']}: already carries #{label_id}")
        return
      end

      Client.new.add_shared_label(
        conversation_id: conversation['id'],
        label_id: label_id,
        organization: conversation.dig('organization', 'id')
      )
      logger.info("labelled #{conversation['id']} as #{label_id} (delivery #{delivery_key[0, 12]})")
    end

    private

    def already_labelled?(conversation, label_id)
      Array(conversation['shared_labels']).any? { |l| l['id'] == label_id }
    end

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
