# frozen_string_literal: true

require 'json'

RSpec.describe Missive::ClassifyConversationWorker do
  let(:label_id) { '9825718b-3407-40b8-800d-a27361c86102' }
  let(:endpoint) { 'https://public.missiveapp.com/v1/conversations/c-1' }

  let(:conversation) do
    {
      'id' => 'c-1',
      'organization' => {'id' => 'org-1', 'name' => 'Fellowship'},
      'shared_labels' => []
    }
  end
  let(:payload) { {'rule' => {'id' => 'r-1', 'type' => 'label_change'}, 'conversation' => conversation} }

  around do |example|
    ENV['MISSIVE_LABEL_LABEL_CHANGE'] = label_id
    ENV['MISSIVE_API_TOKEN'] = 'token'
    example.run
    ENV.delete('MISSIVE_LABEL_LABEL_CHANGE')
    ENV.delete('MISSIVE_API_TOKEN')
  end

  def work
    described_class.new.perform('delivery-key-0123456789', payload)
  end

  # The endpoint is PATCH /v1/conversations/:id, not a post into the thread.
  # The documentation offers it precisely to "label ... conversations
  # silently", and a classifier that announced itself in every thread would be
  # a worse product decision than a wrong label.
  it 'labels the conversation silently, in the bulk-shaped body the API asks for' do
    stub = stub_request(:patch, endpoint)
           .with(
             headers: {'Authorization' => 'Bearer token', 'Content-Type' => 'application/json'},
             body: {conversations: [{id: 'c-1', add_shared_labels: [label_id], organization: 'org-1'}]}
           )
           .to_return(status: 200, body: '{"conversations":[{"id":"c-1"}]}')

    work
    expect(stub).to have_been_requested
  end

  # "When the update changes shared labels, label change rules still run."
  # Our own write can therefore wake our own webhook with a fresh event -- a
  # different payload, a different delivery key, invisible to de-duplication.
  # The payload already carries shared_labels, so the loop closes without an
  # extra request.
  it 'writes nothing when the conversation already carries the label' do
    conversation['shared_labels'] = [{'id' => label_id, 'name' => 'Elfs'}]
    work
    expect(WebMock).not_to have_requested(:any, /missiveapp/)
  end

  it 'writes nothing when no label is configured for the rule type' do
    ENV.delete('MISSIVE_LABEL_LABEL_CHANGE')
    work
    expect(WebMock).not_to have_requested(:any, /missiveapp/)
  end

  # Sidekiq's retries, not Missive's. Missive has already been told the
  # delivery was accepted, so a failure here must never look like one there.
  it 'raises on an API error so Sidekiq retries it, not Missive' do
    stub_request(:patch, endpoint).to_return(status: 502, body: '')
    expect { work }.to raise_error(Missive::Client::Error, /502/)
  end
end
