#!/usr/bin/env python3
"""Проверка XAML до запуска на Windows: компилятор не ловит ссылку на несуществующий ресурс,
а приложение от неё падает при открытии окна. Проверяем, что каждый {StaticResource X} определён
(в App.xaml — выше места использования) и что каждый файл — корректный XML."""
import re, sys, glob, xml.dom.minidom
app = open('Sufler.Win/App.xaml', encoding='utf-8').read()
app_keys = {m.group(1): m.start() for m in re.finditer(r'x:Key="([^"]+)"', app)}
bad = 0
for path in ['Sufler.Win/App.xaml'] + sorted(glob.glob('Sufler.Win/*.xaml') + glob.glob('Sufler.Win/Views/*.xaml')):
    text = open(path, encoding='utf-8').read()
    try: xml.dom.minidom.parseString(text.encode('utf-8'))
    except Exception as e: print(f'{path}: не XML: {e}'); bad += 1
    local = {m.group(1): m.start() for m in re.finditer(r'x:Key="([^"]+)"', text)}
    for m in re.finditer(r'\{StaticResource ([A-Za-z0-9_]+)\}', text):
        key, pos = m.group(1), m.start()
        if path.endswith('App.xaml'):
            if key not in app_keys or app_keys[key] > pos: print(f'{path}: «{key}» используется раньше, чем определён'); bad += 1
        elif key in local:
            if local[key] > pos: print(f'{path}: «{key}» используется раньше, чем определён'); bad += 1
        elif key not in app_keys: print(f'{path}: ресурс «{key}» не определён'); bad += 1
    # Свойства, которые нельзя задавать через стиль: приложение падает при открытии окна
    for m in re.finditer(r'<Setter Property="(WindowStartupLocation|Owner|DialogResult|Icon2)"', text):
        print(f'{path}: свойство «{m.group(1)}» нельзя задавать в стиле'); bad += 1
print('XAML: ошибок', bad)
sys.exit(1 if bad else 0)
