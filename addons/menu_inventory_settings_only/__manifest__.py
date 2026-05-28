{
    "name": "Inventory and Settings Menus Only",
    "version": "1.0",
    "category": "Administration",
    "summary": "Limit the app switcher to Inventory and Settings.",
    "depends": ["base", "base_setup", "mail", "stock"],
    "data": [
        "security/ir.model.access.csv",
        "security/menu_access.xml",
    ],
    "installable": True,
    "application": False,
    "author": "KCG",
    "license": "LGPL-3",
}
