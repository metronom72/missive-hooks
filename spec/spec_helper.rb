# frozen_string_literal: true

ENV['RACK_ENV'] = 'test'

require 'rack/test'
require 'sidekiq/testing'
require 'webmock/rspec'

require_relative '../app/webhook_app'
require_relative '../lib/missive/delivery_log'

Sidekiq::Testing.fake!

# A stand-in for Redis that implements exactly the two calls DeliveryLog makes.
#
# Not a mock: it holds state, so a test can send the same delivery twice and
# watch the second one lose. A mock would only prove that `set` was called with
# `nx: true`, which is the assertion restated rather than tested.
class FakeRedis
  def initialize
    @store = {}
  end

  def set(key, value, nx: false, ex: nil)
    return nil if nx && @store.key?(key)

    @store[key] = value
    'OK'
  end

  def exists?(key)
    @store.key?(key)
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  config.before do
    Sidekiq::Job.clear_all
  end
end
