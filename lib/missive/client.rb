# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Missive
  # Thin client for the one API call this service makes.
  #
  # net/http rather than a gem: one POST does not earn a dependency, and a
  # reader can see exactly what goes over the wire.
  class Client
    BASE_URL = ENV.fetch('MISSIVE_API_BASE_URL', 'https://public.missiveapi.com/v1')

    class Error < StandardError; end

    def initialize(token: ENV['MISSIVE_API_TOKEN'], open_timeout: 2, read_timeout: 5)
      @token = token
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Timeouts are short on purpose. This runs in a worker, so it is not
    # racing the 15 second budget -- but a call that hangs holds a Sidekiq
    # thread, and a queue that fills up is how a healthy-looking service stops
    # doing its job.
    def add_label(conversation_id:, label_id:)
      post("/conversations/#{conversation_id}/labels", labels: [label_id])
    end

    private

    def post(path, body)
      uri = URI.join("#{BASE_URL}/", path.delete_prefix('/'))
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{@token}"
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)

      response = http.request(request)
      return JSON.parse(response.body.to_s) if response.is_a?(Net::HTTPSuccess)

      raise Error, "#{response.code} #{response.message}"
    end
  end
end
