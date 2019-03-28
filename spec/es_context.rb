# frozen_string_literal: true

require 'es_rollover'

require 'securerandom'
require 'logasm'
require 'faraday'
require 'faraday_middleware'

RSpec.shared_context 'with Elasticsearch' do
  let(:test_identifier) { SecureRandom.hex[0..6] }
  let(:es) do
    Faraday.new(
      'http://localhost:9200',
      headers: {'Content-Type' => 'application/json'}
    ) do |conn|
      conn.request(:json)
      conn.response(:json, content_type: /\bjson$/)
      conn.use(Faraday::Response::RaiseError)
      conn.adapter(Faraday.default_adapter)
    end
  end

  after { es.delete("*#{test_identifier}*") }

  def post_event(index:, message:, mapping_type: '_doc')
    es.post("#{index}/#{mapping_type}/#{SecureRandom.hex}", message: message)
  end

  def create_index(index:)
    es.put(index)
  end

  def create_alias(to:, name:) # rubocop:disable Naming/UncommunicativeMethodParamName
    es.put("#{to}/_alias/#{name}")
  end

  def refresh(index:)
    es.post("#{index}/_refresh")
  end

  def es_rollover(max_age: nil, max_size: nil)
    ESRollover.new(
      logger: test_logger,
      elasticsearch_url: es.url_prefix,
      max_age: max_age || '1d',
      max_size: max_size || '1gb',
      reindex_wait_for_active_shards: 1,
      reindex_timeout_seconds: 10,
      reindex_requests_per_second: 500
    )
  end

  private

  def test_logger
    instance_double(Logasm).tap do |mock_logger|
      allow(mock_logger).to receive(:info)
    end
  end

  matcher :have_index do |expected|
    match do |es|
      indices(es).include?(expected)
    end
    failure_message do |es|
      "expected #{indices(es)} to include index #{expected}"
    end
    failure_message_when_negated do |es|
      "expected #{indices(es)} not to include index #{expected}"
    end

    def indices(es) # rubocop:disable Naming/UncommunicativeMethodParamName
      es.get('_all').body.keys
    end
  end

  matcher :have_event do |message:|
    match do |index_name|
      es.get("#{index_name}/_search").body.fetch('hits').fetch('hits')
        .map { |hit| hit.fetch('_source').fetch('message') }
        .include?(message)
    end
  end
end
