#!/usr/bin/env bash
# renovate: datasource=docker depName=example.invalid/team/app
kubectl run test --restart=Never \
  --image=example.invalid/team/app:1.2.3@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
