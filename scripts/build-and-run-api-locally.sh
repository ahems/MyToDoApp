#!/bin/bash

# Navigate to the directory containing the Dockerfile
cd ./api

# Build the Docker image
docker build -t my-api-image .

# Run the Docker container with environment variables
docker run -d -p 5000:5000 --name my-api-container \
  -e DATABASE_CONNECTION_STRING=$DATABASE_CONNECTION_STRING \
  -e APPLICATION_ID=$APPLICATION_ID \
  -e ISSUER=$ISSUER \
  my-api-image