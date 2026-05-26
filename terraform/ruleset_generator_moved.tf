moved {
  from = aws_cloudwatch_log_group.lambda_ip_fallback
  to   = aws_cloudwatch_log_group.ruleset_generator
}

moved {
  from = aws_iam_role.lambda_ip_fallback
  to   = aws_iam_role.ruleset_generator
}

moved {
  from = aws_iam_role_policy.lambda_ip_fallback
  to   = aws_iam_role_policy.ruleset_generator
}

moved {
  from = aws_lambda_function.lambda_ip_fallback
  to   = aws_lambda_function.ruleset_generator
}

moved {
  from = aws_cloudwatch_event_rule.lambda_ip_fallback
  to   = aws_cloudwatch_event_rule.ruleset_generator
}

moved {
  from = aws_cloudwatch_event_target.lambda_ip_fallback
  to   = aws_cloudwatch_event_target.ruleset_generator
}

moved {
  from = aws_lambda_permission.lambda_ip_fallback_events
  to   = aws_lambda_permission.ruleset_generator_events
}

moved {
  from = aws_networkfirewall_rule_group.lambda_ip_fallback
  to   = aws_networkfirewall_rule_group.ruleset_generator
}
