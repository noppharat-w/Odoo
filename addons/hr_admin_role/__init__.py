# -*- coding: utf-8 -*-

from odoo import Command

from . import models


def post_init_hook(env):
    """Attach installed HR manager groups to the HR Admin role when available."""
    hr_admin_group = env.ref('hr_admin_role.group_hr_admin', raise_if_not_found=False)
    if not hr_admin_group:
        return

    optional_group_xmlids = [
        'hr.group_hr_manager',
        'hr.group_hr_user',
        'hr_contract.group_hr_contract_manager',
        'hr_attendance.group_hr_attendance_manager',
        'hr_holidays.group_hr_holidays_manager',
        'hr_recruitment.group_hr_recruitment_manager',
        'hr_expense.group_hr_expense_manager',
        'hr_timesheet.group_hr_timesheet_manager',
        'hr_payroll.group_hr_payroll_manager',
    ]

    installed_groups = [
        group.id
        for xmlid in optional_group_xmlids
        if (group := env.ref(xmlid, raise_if_not_found=False))
    ]
    if installed_groups:
        hr_admin_group.write({
            'implied_ids': [Command.link(group_id) for group_id in installed_groups],
        })
