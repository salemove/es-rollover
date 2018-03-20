# es-rollover

Rolling over dynamically generated Elasticsearch indices

## Running tests

Tests expect an Elasticsearch instance to be available at
`localhost:9200`. In the development environment it can be quickly started
with docker:

```bash
docker run -p 9200:9200 -e "discovery.type=single-node" docker.elastic.co/elasticsearch/elasticsearch-oss:6.2.2
```

After that, linter and tests can be run with:

```bash
bin/rubocop
bin/rspec
```
