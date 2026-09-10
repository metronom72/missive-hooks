# frozen_string_literal: true

require 'json'

RSpec.describe Missive::WebhookApp do
  include Rack::Test::Methods

  let(:secret) { 'signature-secret-from-the-rule' }
  let(:delivery_log) { Missive::DeliveryLog.new(FakeRedis.new) }

  let(:payload) do
    {
      'rule' => { 'id' => 'r-1', 'description' => 'Notify elfs', 'type' => 'label_change' },
      'conversation' => { 'id' => 'c-1', 'subject' => 'Mordor GPS coordinates' }
    }
  end
  let(:raw) { JSON.generate(payload) }

  def app
    described_class.set :signature_secret, secret
    described_class.set :delivery_log, delivery_log
    described_class
  end

  def deliver(body: raw, signature: nil)
    post '/webhooks/missive', body,
         'CONTENT_TYPE' => 'application/json',
         'HTTP_X_HOOK_SIGNATURE' => signature || Missive::Signature.compute(body, secret)
  end

  describe 'signature verification' do
    it 'accepts a request signed with the rule secret' do
      deliver
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)['status']).to eq('accepted')
    end

    it 'refuses a signature computed with a different secret' do
      deliver(signature: Missive::Signature.compute(raw, 'someone-elses-secret'))
      expect(last_response.status).to eq(401)
      expect(Missive::ClassifyConversationWorker.jobs).to be_empty
    end

    it 'refuses a request with no signature header at all' do
      post '/webhooks/missive', raw, 'CONTENT_TYPE' => 'application/json'
      expect(last_response.status).to eq(401)
    end

    # The signature is computed over the raw bytes. Signing a re-serialised
    # parse would pass against our own fixtures and fail against Missive: key
    # order and whitespace do not survive a parse/dump round trip. This body
    # is the same object with different bytes, and it must still verify.
    it 'verifies the bytes on the wire, not a re-serialised parse' do
      spaced = "{\n  \"rule\": {\"id\": \"r-1\", \"type\": \"label_change\"},\n  \"conversation\": {\"id\": \"c-1\"}\n}"
      deliver(body: spaced)
      expect(last_response.status).to eq(200)
    end
  end

  describe 'idempotency' do
    # Five retries over eight minutes make a duplicate the normal case, so
    # this is the expected path and not the sad one.
    it 'accepts the first delivery and recognises the retry as a duplicate' do
      deliver
      expect(JSON.parse(last_response.body)['status']).to eq('accepted')

      deliver
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)['status']).to eq('duplicate')
    end

    it 'enqueues the work exactly once across the full retry budget' do
      (Missive::DeliverySemantics::MAX_RETRIES + 1).times { deliver }
      expect(Missive::ClassifyConversationWorker.jobs.size).to eq(1)
    end

    it 'does not collapse two genuinely different events' do
      deliver
      other = JSON.generate(payload.merge('conversation' => { 'id' => 'c-2' }))
      deliver(body: other)
      expect(JSON.parse(last_response.body)['status']).to eq('accepted')
      expect(Missive::ClassifyConversationWorker.jobs.size).to eq(2)
    end
  end

  describe 'malformed payloads' do
    # Acknowledged and dropped rather than 500'd: more than fifty consecutive
    # failures disable the rule, and one unreadable event class would walk it
    # there while every dashboard still showed a healthy endpoint.
    it 'acknowledges and drops a body that is not JSON' do
      deliver(body: '{ this is not json')
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)['status']).to eq('dropped')
      expect(Missive::ClassifyConversationWorker.jobs).to be_empty
    end

    it 'acknowledges and drops JSON that carries no rule' do
      deliver(body: JSON.generate('hello' => 'world'))
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)['status']).to eq('dropped')
    end
  end

  describe 'acknowledge before work' do
    # The point is not speed, it is what sits on the request path. No outbound
    # call belongs there: WebMock would fail the test if one were made.
    it 'answers without calling the Missive API' do
      deliver
      expect(last_response.status).to eq(200)
      expect(WebMock).not_to have_requested(:any, /missive/)
    end

    it 'hands the worker the delivery key and the parsed payload' do
      deliver
      job = Missive::ClassifyConversationWorker.jobs.first
      expect(job['args'].first).to eq(Missive::DeliveryLog.key_for(raw))
      expect(job['args'].last.dig('conversation', 'id')).to eq('c-1')
    end
  end

  describe 'health' do
    it 'answers /healthz without a signature' do
      get '/healthz'
      expect(last_response.status).to eq(200)
    end
  end
end
