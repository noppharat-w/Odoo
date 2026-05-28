from odoo import api, models


class IrUiMenu(models.Model):
    _inherit = "ir.ui.menu"

    @api.model
    def _should_limit_root_menus(self):
        return not self.env.user.has_group("base.group_system")

    @api.model
    def _limited_root_menu_ids(self):
        xmlids = [
            "stock.menu_stock_root",
            "base.menu_administration",
        ]

        menu_ids = set()
        for xmlid in xmlids:
            menu = self.env.ref(xmlid, raise_if_not_found=False)
            if menu:
                menu_ids.add(menu.id)
        return menu_ids

    @api.model
    def _limited_root_menu_blacklist(self):
        if not self._should_limit_root_menus():
            return []
        allowed_ids = self._limited_root_menu_ids()
        root_ids = self.sudo().search([("parent_id", "=", False)]).ids
        return [menu_id for menu_id in root_ids if menu_id not in allowed_ids]

    def _load_menus_blacklist(self):
        blacklist = set(super()._load_menus_blacklist())
        blacklist.update(self._limited_root_menu_blacklist())
        return list(blacklist)

    @api.model
    def get_user_roots(self):
        roots = super().get_user_roots()
        if not self._should_limit_root_menus():
            return roots
        allowed_ids = self._limited_root_menu_ids()
        return roots.filtered(lambda menu: menu.id in allowed_ids)
