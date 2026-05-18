set dotenv-load := true

network := "testnet"

default:
    @just --list

create:
    oasis rofl create --network {{network}}

build:
    oasis rofl build

set-secrets:
    @test -f .env || (echo ".env not found — copy .env.example and fill it in" && exit 1)
    oasis rofl secret import --force .env

update:
    oasis rofl update

deploy:
    oasis rofl deploy

show:
    oasis rofl machine show

logs:
    oasis rofl machine logs

identity:
    oasis rofl identity

trust-root:
    oasis rofl trust-root

ship: build set-secrets update deploy
