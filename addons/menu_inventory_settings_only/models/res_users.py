from odoo import models, tools


class ResUsers(models.Model):
    _inherit = "res.users"

    @tools.ormcache("self.id")
    def _get_group_ids(self):
        group_ids = set(super()._get_group_ids())
        internal_user_id = self.env["ir.model.data"]._xmlid_to_res_id(
            "base.group_user", raise_if_not_found=False
        )
        stock_user_id = self.env["ir.model.data"]._xmlid_to_res_id(
            "stock.group_stock_user", raise_if_not_found=False
        )
        if internal_user_id in group_ids and stock_user_id:
            group_ids.add(stock_user_id)
        return tuple(group_ids)
