# frozen_string_literal: true

# These are not tests of our code. They are a tripwire on somebody else's
# documentation: every one of these numbers is quoted in the README and drives
# a design decision, so a silent edit here would leave the prose lying about
# the code. If Missive changes the contract, this file is where it is noticed.
RSpec.describe Missive::DeliverySemantics do
  it 'names the signature header exactly as the documentation does' do
    expect(described_class::SIGNATURE_HEADER).to eq('X-Hook-Signature')
  end

  it 'expects a hexdigest behind a sha256= prefix, not Base64' do
    expect(described_class::SIGNATURE_PREFIX).to eq('sha256=')
    signature = Missive::Signature.compute('{}', 'secret')
    expect(signature).to match(/\Asha256=[0-9a-f]{64}\z/)
  end

  it 'holds the 15 second response budget that puts the work in a queue' do
    expect(described_class::RESPONSE_BUDGET_SECONDS).to eq(15)
  end

  it 'holds the retry budget that makes duplicates normal' do
    expect(described_class::MAX_RETRIES).to eq(5)
    expect(described_class::RETRY_WINDOW_SECONDS).to eq(8 * 60)
  end

  it 'holds the failure streak that makes dropping safer than 500ing' do
    expect(described_class::AUTO_DISABLE_AFTER_CONSECUTIVE_FAILURES).to eq(50)
  end

  # A delivery key that expired inside the retry window would let a late retry
  # through as a fresh delivery -- the exact duplicate the key exists to stop.
  it 'remembers a delivery for longer than Missive keeps retrying it' do
    expect(described_class::DELIVERY_KEY_TTL_SECONDS)
      .to be > described_class::RETRY_WINDOW_SECONDS
  end
end
