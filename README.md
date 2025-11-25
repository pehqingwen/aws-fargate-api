Networking: 
- A VPC in ap-southeast-1 with multiple subnets in 2-3 availability zones
- An ECS Fargate service runs the Node.js container: The container image is built locally, pushed to Amazon ECR, and referenced in the ECS task definition. The service registers tasks in a target group used by the ALB.

Security: 
- Included security groups such as ALB security group (Ingress, Egress) & Aurora security group
- AWS Web Application Firewall: A WAFv2 Web ACL is attached to the ALB, uses AWS-managed rule groups to protect against common web attacks (SQL injection, XSS, etc.)
- CloudTrail enabled to log API activity in the account, GuardDuty enabled for threat detection, Security Hub enabled to aggregate security findings and best-practice checks.
