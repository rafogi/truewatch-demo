resource "truewatch_dashboard" "todo_app_demo" {
  name        = "todo-app Demo Dashboard"
  desc        = "Flask to-do app on AKS -- APM + infra monitoring demo"
  is_public   = 0
  identifier  = "todo-app-demo"
  tag_names = [
    "todo-app",
    "terraform",
  ]

  template_info = file("dashboard.json")
}

output "dashboard_uuid" {
  value       = truewatch_dashboard.todo_app_demo.uuid
  description = "The UUID of the created dashboard -- use this to build a direct console link"
}
