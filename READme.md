#### Kubernets CLI Commands

## Install minikube on windows
choco install minikube

## Start minikube
minikube start 

## Enable ingress 
minikube addons enable ingress

## Open a cmd terminal and enter
minikube tunnel 

## To execute the Deployment, Service and Ingress file execute the below commands
cd Kubernetes_Operations

kubectl apply -f .

## To view page exeute the below command in another cmd terminal
curl --resolve "www.example.com:80:127.0.0.1" -i http://www.example.com