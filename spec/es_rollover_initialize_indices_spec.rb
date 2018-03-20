# frozen_string_literal: true

require 'es_rollover'
require_relative 'es_context'

RSpec.describe ESRollover, '#initialize_indices' do
  include_context 'with Elasticsearch'

  it 'only initializes *-*-log indices' do
    rollover_index_name = "test-#{test_identifier}-log"
    other_index_name = "test-#{test_identifier}-index"

    create_index(index: rollover_index_name)
    create_index(index: other_index_name)
    es_rollover.initialize_indices

    expect(es).not_to have_index(rollover_index_name)
    expect(es).to have_index("#{rollover_index_name}-000001")
    expect(es).to have_index(other_index_name)
  end

  it 'reindexes data into the new suffixed index' do
    index_name = "test-#{test_identifier}-log"
    initialized_index_name = "#{index_name}-000001"
    message = 'Test log'

    post_event(index: index_name, message: message)
    refresh(index: index_name)
    es_rollover.initialize_indices
    refresh(index: initialized_index_name)

    expect(initialized_index_name).to have_event(message: message)
  end

  it 'directs new writes to suffixed index via alias' do
    index_name = "test-#{test_identifier}-log"
    initialized_index_name = "#{index_name}-000001"
    message = 'Test log'

    create_index(index: index_name)
    es_rollover.initialize_indices
    post_event(index: index_name, message: message)
    refresh(index: initialized_index_name)

    expect(initialized_index_name).to have_event(message: message)
  end

  it 'reindexes data into the highest suffixed existing index' do
    index_name = "test-#{test_identifier}-log"
    low_exisiting_suffixed_index = "#{index_name}-000001"
    high_exisiting_suffixed_index = "#{index_name}-000002"
    old_message = 'Old log'
    new_message = 'New log'

    post_event(index: index_name, message: new_message)
    refresh(index: index_name)
    create_index(index: low_exisiting_suffixed_index)
    post_event(index: high_exisiting_suffixed_index, message: old_message)
    es_rollover.initialize_indices
    refresh(index: high_exisiting_suffixed_index)

    expect(high_exisiting_suffixed_index).to have_event(message: old_message)
    expect(high_exisiting_suffixed_index).to have_event(message: new_message)
  end

  it 'directs new writes to the highest suffixed existing index' do
    index_name = "test-#{test_identifier}-log"
    low_exisiting_suffixed_index = "#{index_name}-000001"
    high_exisiting_suffixed_index = "#{index_name}-000002"
    message = 'Test log'

    create_index(index: index_name)
    create_index(index: low_exisiting_suffixed_index)
    create_index(index: high_exisiting_suffixed_index)
    es_rollover.initialize_indices
    post_event(index: index_name, message: message)
    refresh(index: high_exisiting_suffixed_index)

    expect(high_exisiting_suffixed_index).to have_event(message: message)
  end
end
