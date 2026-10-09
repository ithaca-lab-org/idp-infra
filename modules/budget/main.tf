resource "google_billing_budget" "this" {
  billing_account = var.billing_account_id
  display_name    = var.display_name

  budget_filter {
    projects = ["projects/${var.project_number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.amount_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.thresholds
    content {
      threshold_percent = threshold_rules.value
    }
  }

  # Forecasted overspend warns before the money is gone.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }
}
