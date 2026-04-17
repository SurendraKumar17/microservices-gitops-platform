# Production-Grade Microservices Platform on Kubernetes

This project demonstrates a real-world DevOps architecture using:

- Terraform for infrastructure provisioning
- AWS (EKS, VPC, IAM)
- Kubernetes for orchestration
- CI/CD pipelines for automation
- Prometheus & Grafana for monitoring
- CloudWatch for alerting and scaling

## Architecture

User → Load Balancer → Kubernetes (EKS)
                          ↓
                  Microservices (Docker)
                          ↓
        Monitoring → Prometheus + Grafana
                          ↓
        Logging → ELK Stack
                          ↓
        Alerts → CloudWatch

## Goals

- Build a production-grade microservices system
- Implement auto-scaling (HPA + ASG)
- Add observability (metrics, logs, alerts)
- Practice real-world debugging scenarios
- Prepare for DevOps interviews

## Tech Stack

- Terraform
- Kubernetes
- Docker
- AWS
- GitHub Actions
- Prometheus, Grafana

## Progress

- [ ] Terraform backend setup
- [ ] VPC creation
- [ ] EKS cluster
- [ ] Microservices deployment
- [ ] CI/CD pipeline
- [ ] Monitoring & alerts
