FROM lambci/lambda:build-ruby2.7

ENV AWS_DEFAULT_REGION ap-northeast-1

COPY Gemfile* ./
RUN bundle install --deployment

COPY . .

RUN zip -9yr lambda.zip .

CMD aws lambda update-function-code --function-name daily_hanihani --zip-file fileb://lambda.zip
