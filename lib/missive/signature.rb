# frozen_string_literal: true

require 'openssl'
require_relative 'delivery_semantics'

module Missive
  # Verification of the X-Hook-Signature header.
  #
  # Deliberately computed over the RAW request body. Re-serialising parsed JSON
  # and signing that would pass every test written against our own fixtures and
  # fail against Missive, because key order and whitespace are not preserved by
  # a parse/dump round trip.
  module Signature
    module_function

    # @param body [String] the exact bytes of the request body
    # @param secret [String] the "Signature secret" set on the Missive rule
    # @return [String] header value, including the sha256= prefix
    def compute(body, secret)
      DeliverySemantics::SIGNATURE_PREFIX + OpenSSL::HMAC.hexdigest(
        OpenSSL::Digest.new(DeliverySemantics::SIGNATURE_DIGEST), secret, body
      )
    end

    # Constant-time comparison, as the documentation asks for explicitly:
    # "assess equality ... using a method that prevents timing attacks against
    # regular equality operators."
    #
    # A nil or empty header is not passed to secure_compare -- it raises on
    # length mismatch in some OpenSSL builds, and an unsigned request is not a
    # near miss worth measuring.
    def valid?(body, secret, provided)
      return false if provided.nil? || provided.empty?

      expected = compute(body, secret)
      return false unless expected.bytesize == provided.bytesize

      OpenSSL.secure_compare(expected, provided)
    end
  end
end
