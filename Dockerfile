FROM ruby:2.5.0

RUN apt-get update -qq && apt-get install -y build-essential supervisor libpq-dev imagemagick

ENV APP_ROOT /usr/src/app
RUN mkdir -p $APP_ROOT
WORKDIR $APP_ROOT
COPY . .

RUN bundle
