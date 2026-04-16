# **Eunomia Deployment**

This repository contains artifacts and scripts to deploy and test the Eunomia framework. It includes example certificates for authority, provider, and consumer, a central docker-compose file, and automation scripts in Bash or Powershell.

## **Deployment Methods**

There are two main ways to deploy this environment:

1. **[Mini Deployment](./deployment/mini/README.md)**: A lightweight deployment using Docker Compose. Click the link to see the specific guide.
2. **[Prod Deployment](./deployment/prod/README.md)**: Production deployment (currently empty/WIP).

## **Requirements**

- Docker and docker-compose (or Docker Desktop)
- Permissions to execute scripts (chmod +x)

## **External Dependencies**

This project depends on a wallet infrastructure (e.g. walt.id) and other components. Please see the specific deployment method instructions (such as **[Mini Deployment](./deployment/mini/README.md)**) for detailed setup steps.

