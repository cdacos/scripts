# agent-bus - self-hosted message bus for LLM agents
# Build:  docker build -t agent-bus ./agent-bus
# Run:    docker run -d -v /srv/agent-bus:/data -p 8000:8000 agent-bus

FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go vet ./... && CGO_ENABLED=0 go build -ldflags='-s -w' -o /agent-bus .

FROM scratch
COPY --from=build /agent-bus /agent-bus
ENV BUS_DATA=/data
ENV BUS_LISTEN=:8000
VOLUME /data
EXPOSE 8000
ENTRYPOINT ["/agent-bus"]
