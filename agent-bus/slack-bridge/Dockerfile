# slack-bridge - Slack <-> agent-bus bridge
# Build:  docker build -t slack-bridge ./agent-bus/slack-bridge
# Run:    docker run -d -v ./bridge-config.json:/config.json:ro \
#           -e AGENT_BUS_URL=... -e AGENT_BUS_TOKEN=... \
#           -e SLACK_BOT_TOKEN=... -e SLACK_SIGNING_SECRET=... slack-bridge

FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go vet ./... && CGO_ENABLED=0 go build -ldflags='-s -w' -o /slack-bridge .

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=build /slack-bridge /slack-bridge
ENV BRIDGE_LISTEN=:8100
EXPOSE 8100
ENTRYPOINT ["/slack-bridge"]
