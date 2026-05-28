# -*- coding: utf-8 -*-
{
    'name': 'HR Admin Role',
    'version': '1.0',
    'summary': 'Adds an HR Admin role with focused settings access',
    'category': 'Human Resources',
    'depends': ['base', 'base_setup', 'stock'],
    'data': [
        'security/hr_admin_role_security.xml',
        'security/ir.model.access.csv',
        'views/res_config_settings_views.xml',
    ],
    'post_init_hook': 'post_init_hook',
    'installable': True,
    'application': False,
    'license': 'LGPL-3',
}
