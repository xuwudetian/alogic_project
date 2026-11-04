# alogic_project

双 FPGA 工程与 Python 串口监测上位机，包含 A 板、B 板源码、工程配置、仿真文件、烧录文件和已有验证记录。

## 目录

| 目录 | 内容 |
| --- | --- |
| `A_project/` | A 板 FPGA 工程、HDL/IP、约束、仿真及验证记录 |
| `B_project/` | B 板 FPGA 工程、HDL/IP、约束、模型数据、仿真及验证记录 |
| `UP-C/` | 应急系统上位机源码、串口协议、测试及 Windows 可执行程序 |

## FPGA 工程

工程文件记录的工具版本为 Tang Dynasty `6.2.168116`，目标器件为 `EG4S20BG256`。

- A 板工程：[`A_project.al`](A_project/src/td_project/A_project.al)
- B 板工程：[`B_project.al`](B_project/src/td_project/B_project.al)
- A 板烧录文件与构建记录：[`A_project/download/build_1/`](A_project/download/build_1/)
- B 板烧录文件与构建记录：[`B_project/download/build_1/`](B_project/download/build_1/)

使用 Tang Dynasty 打开对应的 `.al` 工程。工程中的 `Path` 属性记录了原开发电脑的绝对路径，换目录后请在工具中核对工程位置、源文件及 IP 路径。

## 上位机

Windows 可直接运行 `UP-C/release/应急系统.exe`，或双击 `UP-C/run_emergency_system.bat`。

从源码运行需要 Python 3.10 或更新版本（含 Tkinter）：

```powershell
cd UP-C
python -m pip install -r requirements.txt
python emergency_system.py
```

详细功能、接线、串口参数和协议见 [`UP-C/README.md`](UP-C/README.md)。

## 版本管理范围

保留源码、工程配置、IP 与模型数据、烧录文件、上位机发布程序和已有验证记录。虚拟环境、Tang Dynasty 综合与布局布线工作目录、Python/仿真缓存和本机设置不纳入版本管理；这些文件仍保留在本地。
