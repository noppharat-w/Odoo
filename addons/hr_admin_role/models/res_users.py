# -*- coding: utf-8 -*-

from odoo import api, fields, models


class ResUsers(models.Model):
    _inherit = 'res.users'

    role = fields.Selection(selection_add=[('group_hr_admin', 'HR Admin')])

    def _has_explicit_hr_admin_group(self):
        self.ensure_one()
        group_hr_admin = self.env.ref('hr_admin_role.group_hr_admin')
        return (
            group_hr_admin in self.group_ids
            or group_hr_admin in self.group_ids._origin
            or group_hr_admin.id in self.group_ids._origin.ids
        )

    @api.depends('group_ids')
    def _compute_role(self):
        super()._compute_role()
        for user in self:
            if user._has_explicit_hr_admin_group():
                user.role = 'group_hr_admin'

    @api.onchange('role')
    def _onchange_role(self):
        group_hr_admin = self.env['res.groups'].new(origin=self.env.ref('hr_admin_role.group_hr_admin'))
        group_admin = self.env['res.groups'].new(origin=self.env.ref('base.group_system'))
        group_user = self.env['res.groups'].new(origin=self.env.ref('base.group_user'))
        for user in self:
            if not user.role:
                continue
            groups = user.group_ids - (group_hr_admin + group_admin + group_user)
            if user.role == 'group_hr_admin':
                groups += group_hr_admin
            elif user.role == 'group_system':
                groups += group_admin
            elif user.role == 'group_user':
                groups += group_user
            user.group_ids = groups
