# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Missive
  # Thin client for the one API call this service makes.
  #
  # net/http rather than a gem: one PATCH does not earn a dependency, and a
  # reader can see exactly what goes over the wire.
  class Client
    # https://missiveapp.com/docs/developers/rest-api -- "https://public.missiveapp.com/v1/:endpoint_name"
    BASE_URL = ENV.fetch('MISSIVE_API_BASE_URL', 'https://public.missiveapp.com/v1')

    class Error < StandardError; end

    def initialize(token: ENV['MISSIVE_API_TOKEN'], open_timeout: 2, read_timeout: 5)
      @token = token
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Labels a conversation without posting into it.
    #
    # PATCH /v1/conversations/:id, not a post: the documentation is explicit
    # that this endpoint exists to "close, reopen, move, assign, label,
    # recolor, or rename conversations silently". A classifier that announced
    # itself in the thread every time would be a worse product decision than a
    # wrong label.
    #
    # The body wraps a one-element array because the endpoint is bulk-shaped:
    # "The request body must include a conversations array with exactly one
    # object for each ID in the URL."
    #
    # Timeouts are short on purpose. This runs in a worker, so it is not racing
    # the 15 second response budget -- but a call that hangs holds a Sidekiq
    # thread, and a queue that fills up is how a healthy-looking service stops
    # doing its job.
    def add_shared_label(conversation_id:, label_id:, organization: nil)
      conversation = {'id' => conversation_id, 'add_shared_labels' => [label_id]}
      conversation['organization'] = organization if organization

      patch("/conversations/#{conversation_id}", 'conversations' => [conversation])
    end

    private

    def patch(path, body)
      uri = URI.join("#{BASE_URL}/", path.delete_prefix('/'))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      request = Net::HTTP::Patch.new(uri)
      request['Authorization'] = "Bearer #{@token}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)

      response = http.request(request)
      return JSON.parse(response.body.to_s) if response.is_a?(Net::HTTPSuccess)

      raise Error, "#{response.code} #{response.message}"
    end
  end
end
