# Changelog

## 4.0 patch 1

- **Оболочка вынесена в модуль `FSH.FAP`** (apps/fsh.asm): редактор строки, история (16 команд, `/SYSTEM/FSH.HIS`),
  Tab-дополнение, `help`. Ядро запускает её после загрузки; без файла — `EMERGENCY MODE` и минимальная оболочка ядра.
- **Утилиты — отдельные программы** в `/SYSTEM/SYSAPPS/FSH`: `fetch cpu mem date time echo hex bin ascii matrix banner
  osinfo credits`. В ядре остались только команды FAT, `run`/`sh`, настройка, `view`, `play`, `clear`, `reboot`/`shutdown`.
  Ядро похудело с 35,7 до 31,7 КБ.

- **MBR + раздел**: `ferrix.img` теперь настоящий диск с таблицей разделов (`mbr.asm`, раздел №1 FAT16 с сектора 63, конец на границе цилиндра — геометрию для El Torito HDD BIOS берёт из таблицы);
  загрузчик и ядро учитывают hidden sectors из BPB.

- `date` показывает день недели; исправлен верхний ряд клавиш в `synth`.
