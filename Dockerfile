FROM ruby:2.5-alpine

RUN apk --no-cache add make gcc libc-dev && \
  gem install bundler

ENV APP_HOME /app
RUN mkdir $APP_HOME
WORKDIR $APP_HOME

ADD Gemfile* $APP_HOME/
RUN bundle install --deployment

ADD . $APP_HOME

CMD ["bundle", "exec", "ruby", "start.rb"]
