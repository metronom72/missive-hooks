# frozen_string_literal: true

require 'redis'

# The unit tests run against a stand-in that implements SET NX the way I
# believe Redis implements it. That belief is the part worth checking: the
# `redis` gem has changed what `set` returns more than once, and a claim that
# reads a truthy "OK" for the second writer is a de-duplicator that
# de-duplicates nothing while every test stays green.
#
# Skipped, not failed, when no Redis is listening: this suite has to stay
# runnable by someone who just cloned the repository.
RSpec.describe Missive::DeliveryLog, :redis do
  let(:url) { ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/15') }
  let(:redis) do
    client = Redis.new(url: url)
    client.ping
    client
  rescue StandardError => e
    skip("no Redis at #{url}: #{e.message}")
  end

  let(:key) { described_class.key_for("delivery-#{rand(1 << 32)}") }

  after { redis.del(described_class::KEY_PREFIX + key) if redis.respond_to?(:del) }

  it 'lets the first claim through and refuses every retry' do
    log = described_class.new(redis)
    expect(log.claim(key)).to be(true)
    expect(log.claim(key)).to be(false)
    expect(log.claim(key)).to be(false)
  end

  it 'sets a TTL, so the key cannot outlive the service by accident' do
    described_class.new(redis).claim(key)
    ttl = redis.ttl(described_class::KEY_PREFIX + key)
    expect(ttl).to be > Missive::DeliverySemantics::RETRY_WINDOW_SECONDS
  end

  # WebMock is on for the whole suite and would otherwise refuse the socket.
  around do |example|
    WebMock.allow_net_connect!
    example.run
    WebMock.disable_net_connect!
  end
end
