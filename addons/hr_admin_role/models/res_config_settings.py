# -*- coding: utf-8 -*-

from lxml import etree

from odoo import fields, models


class ResConfigSettings(models.TransientModel):
    _inherit = 'res.config.settings'

    is_hr_admin_role = fields.Boolean(compute='_compute_is_hr_admin_role')

    def _compute_is_hr_admin_role(self):
        is_hr_admin = self.env.user.has_group('hr_admin_role.group_hr_admin')
        for settings in self:
            settings.is_hr_admin_role = is_hr_admin

    def get_view(self, view_id=None, view_type='form', **options):
        result = super().get_view(view_id=view_id, view_type=view_type, **options)
        if view_type == 'form' and self.env.user.has_group('hr_admin_role.group_hr_admin'):
            result['arch'] = self._filter_hr_admin_settings_arch(result['arch'])
        return result

    def _filter_hr_admin_settings_arch(self, arch):
        root = etree.fromstring(arch.encode())

        for app in root.xpath("//app[@name!='general_settings']"):
            app.getparent().remove(app)

        allowed_general_ids = {'invite_users', 'languages', 'companies', 'about'}
        allowed_fields = {'is_root_company', 'is_hr_admin_role'}
        for node in root.xpath("//app[@name='general_settings']/*"):
            if node.get('id') in allowed_general_ids:
                continue
            if node.tag == 'field' and node.get('name') in allowed_fields:
                continue
            node.getparent().remove(node)

        for node in root.xpath("//setting[@id='document_layout_setting' or @id='inter_company']"):
            node.getparent().remove(node)

        return etree.tostring(root, encoding='unicode')
