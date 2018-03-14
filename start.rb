# frozen_string_literal: true

require 'faraday'
require 'faraday_middleware'
require 'logasm'

# The index pattern used by both uninitialized indices and by aliases pointing
# to already initialized indices.
ES_INDEX_PATTERN = '*-*-log'
REGEX_INDEX_PATTERN = /^.*-.*-log$/

$host = ENV.fetch('ELASTICSEARCH_URL', 'http://localhost:9200')
$max_age = ENV.fetch('MAX_AGE', '7d')
$max_docs = Integer(ENV.fetch('MAX_DOCS', '400000000'), 10) # 400m

$logasm = Logasm.build('myApp', stdout: nil)
$es = Faraday.new($host) do |conn|
  conn.request(:json)
  conn.response(:json, content_type: /\bjson$/)
  conn.use(Faraday::Response::RaiseError)
  conn.adapter(Faraday.default_adapter)
end

def format_error(error)
  base_context = {
    error: {
      message: error.message,
      backtrace: error.backtrace.join("\n")
    }
  }

  if error.is_a?(Faraday::ClientError) && error.response
    base_context.merge(status: error.response.fetch(:status))
  else
    base_context
  end
end

def run
  uninitialized_indices.each do |index_name|
    initialize_rollover_for_index(index_name)
  rescue StandardError => e
    $logasm.error('Failed to initialize rollover for index', format_error(e))
    next # continue with other indices
  end

  rollover_aliases.each do |alias_name|
    rollover(alias_name)
  rescue StandardError => e
    $logasm.error('Failed to rollover index', format_error(e))
    next # continue with other aliases
  end
end

def uninitialized_indices
  $es.get(ES_INDEX_PATTERN)
    .body
    .select { |index_name, _index| index_name.match?(REGEX_INDEX_PATTERN) }
    .keys
end

def disable_writes(index_name)
  $logasm.info('Disabling writes for index', index: index_name)
  $es.put("#{index_name}/_settings", 'index.blocks.write': true)
end

def create_name_with_counter_suffix(index_name)
  "#{index_name}-000001"
end

REINDEX_RESULT_CONTEXT = %w[timed_out total created updated took].freeze
def reindex(from:, to:) # rubocop:disable Naming/UncommunicativeMethodParamName
  $logasm.info('Reindexing data from index to rename with suffix', from: from, to: to)
  response = $es.post(
    '_reindex?wait_for_active_shards=all&requests_per_second=500&timeout=1h',
    source: {index: from},
    dest: {index: to}
  ) do |req|
    req.options.timeout = 60 * 60 # an hour in seconds
  end

  log_context = response.body.slice(*REINDEX_RESULT_CONTEXT).merge(from: from, to: to)
  $logasm.info('Reindexing result', log_context)

  return if response.body.fetch('total') >= 1
  $logasm.info('Reindex did not create a new index, creating empty index', from: from, to: to)
  $es.put(to)
end

def replace_index_with_alias(index:, alias_to:)
  $logasm.info('Deleting index and replacing with alias', index: index, alias_to: alias_to)
  $es.post('_aliases', actions: [
    {add: {index: alias_to, alias: index}},
    {remove_index: {index: index}}
  ])
end

def initialize_rollover_for_index(index_name)
  $logasm.info('Starting rollover initialization', index: index_name)
  disable_writes(index_name)
  new_index_name = create_name_with_counter_suffix(index_name)
  reindex(from: index_name, to: new_index_name)
  replace_index_with_alias(index: index_name, alias_to: new_index_name)
end

def rollover_aliases
  $es.get("_alias/#{ES_INDEX_PATTERN}")
    .body
    .values
    .map do |index|
      all_aliases = index.fetch('aliases').keys
      matching_aliases = all_aliases.select { |alias_name| alias_name.match?(REGEX_INDEX_PATTERN) }
      if matching_aliases.count != 1
        $logasm.error(
          'Expected exactly one matching alias',
          all_aliases: all_aliases,
          matching_aliases: matching_aliases
        )
        raise 'Expected exactly one matching alias'
      end
      matching_aliases.first
    end
rescue Faraday::ResourceNotFound => e
  $logasm.warn('Elasticsearch returned 404 for rollover_aliases request', format_error(e))
  []
end

ROLLOVER_RESULT_CONTEXT = %w[old_index new_index rolled_over acknowledged].freeze
def rollover(alias_name)
  $logasm.info('Executing rollover for alias', alias: alias_name)
  response = $es.post("#{alias_name}/_rollover", conditions: {
    max_age: $max_age,
    max_docs: $max_docs
  })

  log_context = response.body.slice(*ROLLOVER_RESULT_CONTEXT).merge(alias: alias_name)
  if response.body.fetch('rolled_over')
    $logasm.info('Successfully rolled over alias to new index', log_context)
  else
    $logasm.info('Skipped rolling over an alias', log_context)
  end
end

run
