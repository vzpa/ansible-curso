#!/usr/bin/python

ANSIBLE_METADATA = {
    'metadata_version': '1.0',
    'status': ['preview'],
    'supported_by': 'community'
}

DOCUMENTATION = '''
---
module: modulo
short_description: Visualiza un texto 
version_added: "2.8"
description:
  - "Este modulo visualiza un texto que se pasa como argumento"
options:
    texto:
        description:
          - Texto a visualizar.
        required: false
        type: str
        default: Esto es una prueba
author:
    - Apasoft Training
'''

EXAMPLES = '''
# Pasa cualquier texto
- name: Pasa un texto
  ejemplo:
    texto: "Estoy pasando un texto al modulo"
'''

RETURN = '''
fact:
  description: Has puesto el texto: cadena
  type: str
  sample: Has puesto el texto: esto es una prueba
'''

import random
from ansible.module_utils.basic import AnsibleModule


FACTS = "Has puesto el texto {texto}!"


def run_module():
    module_args = dict(
        texto=dict(type='str', default='Esto es una prueba'),
    )

    module = AnsibleModule(
        argument_spec=module_args,
        supports_check_mode=True
    )

    result = dict(
        changed=False,
        fact=''
    )

    result['fact'] = FACTS.format(
        texto=module.params['texto']
    )

    if module.check_mode:
        return result

    module.exit_json(**result)


def main():
    run_module()


if __name__ == '__main__':
    main()
