#include<Windows.h>
#include<initguid.h>
#include<devguid.h>
#include<devpropdef.h>
#include<devpkey.h>
#include<setupapi.h>
#include<cfgmgr32.h>
#pragma comment(lib,"setupapi.lib")
#pragma comment(lib,"cfgmgr32.lib")
import std;
//把宽字符串转换为系统ANSI编码的窄字符串用于控制台输出，避免输出乱码
static std::string 宽转窄(const std::wstring& 宽文本)
{
	if (宽文本.empty())
		return {};
	const int 字节数 = WideCharToMultiByte(CP_ACP, 0, 宽文本.c_str(), (int)宽文本.size(), nullptr, 0, nullptr, nullptr);
	std::string 窄文本(字节数, '\0');
	WideCharToMultiByte(CP_ACP, 0, 宽文本.c_str(), (int)宽文本.size(), 窄文本.data(), 字节数, nullptr, nullptr);
	return 窄文本;
}

//运行命令并合并取得其标准输出与错误输出，用于调用nvidia-smi（其输出只含ASCII字符，逐字节转宽字符即可）
static std::wstring 运行命令取得输出(const std::wstring& 命令行)
{
	HANDLE 读端 = nullptr, 写端 = nullptr;
	SECURITY_ATTRIBUTES 安全属性{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
	if (!CreatePipe(&读端, &写端, &安全属性, 0))
		return {};
	SetHandleInformation(读端, HANDLE_FLAG_INHERIT, 0);
	std::vector<wchar_t> 可写命令行(命令行.c_str(), 命令行.c_str() + 命令行.size() + 1);
	STARTUPINFOW 启动信息{sizeof(STARTUPINFOW)};
	启动信息.dwFlags = STARTF_USESTDHANDLES;
	启动信息.hStdOutput = 写端;
	启动信息.hStdError = 写端;
	PROCESS_INFORMATION 进程信息{};
	if (!CreateProcessW(nullptr, 可写命令行.data(), nullptr, nullptr, TRUE, CREATE_NO_WINDOW, nullptr, nullptr, &启动信息, &进程信息))
	{
		CloseHandle(读端);
		CloseHandle(写端);
		return {};
	}
	CloseHandle(写端);
	std::string 多字节输出;
	for (char 缓冲[4096];;)
	{
		DWORD 读取字节数 = 0;
		if (!ReadFile(读端, 缓冲, sizeof(缓冲), &读取字节数, nullptr) || 读取字节数 == 0)
			break;
		多字节输出.append(缓冲, 读取字节数);
	}
	CloseHandle(读端);
	WaitForSingleObject(进程信息.hProcess, INFINITE);
	CloseHandle(进程信息.hProcess);
	CloseHandle(进程信息.hThread);
	return {多字节输出.begin(), 多字节输出.end()};
}

//去除字符串首尾的空白字符
static std::wstring 去除首尾空白(std::wstring 文本)
{
	const auto 首 = 文本.find_first_not_of(L" \t\r\n");
	if (首 == std::wstring::npos)
		return {};
	return 文本.substr(首, 文本.find_last_not_of(L" \t\r\n") - 首 + 1);
}

//在显示适配器类的PnP设备中按PCI总线号与设备号查找NVIDIA显卡，匹配规则与远程桌面修复.ps1一致：只读BusNumber/Address数值属性匹配，不解析位置展示文本以避开中英文混排
static bool 查找显卡设备(unsigned 总线号, unsigned 设备号, std::wstring& 实例标识, HDEVINFO& 设备集, SP_DEVINFO_DATA& 设备信息)
{
	设备集 = SetupDiGetClassDevsW(&GUID_DEVCLASS_DISPLAY, nullptr, nullptr, DIGCF_PRESENT);
	if (设备集 == INVALID_HANDLE_VALUE)
		return false;
	设备信息.cbSize = sizeof(SP_DEVINFO_DATA);
	for (DWORD 序号 = 0; SetupDiEnumDeviceInfo(设备集, 序号, &设备信息); ++序号)
	{
		wchar_t 标识缓冲[512];
		if (!SetupDiGetDeviceInstanceIdW(设备集, &设备信息, 标识缓冲, 512, nullptr))
			continue;
		//只认NVIDIA的PCI显示设备，集成显卡与其它厂商设备不在此列
		if (_wcsnicmp(标识缓冲, L"PCI\\VEN_10DE", 12) != 0)
			continue;
		DEVPROPTYPE 属性类型;
		ULONG 实际总线号 = 0, 设备地址 = 0;
		if (!SetupDiGetDevicePropertyW(设备集, &设备信息, &DEVPKEY_Device_BusNumber, &属性类型, reinterpret_cast<PBYTE>(&实际总线号), sizeof(实际总线号), nullptr, 0))
			continue;
		if (!SetupDiGetDevicePropertyW(设备集, &设备信息, &DEVPKEY_Device_Address, &属性类型, reinterpret_cast<PBYTE>(&设备地址), sizeof(设备地址), nullptr, 0))
			continue;
		//DEVPKEY_Device_Address的高16位是设备号、低16位是功能号
		if (实际总线号 == 总线号 && (设备地址 >> 16) == 设备号)
		{
			实例标识 = 标识缓冲;
			return true;
		}
	}
	SetupDiDestroyDeviceInfoList(设备集);
	设备集 = nullptr;
	return false;
}

//以设备管理器同款的DIF_PROPERTYCHANGE方式启用或禁用设备节点
static bool 设置设备启用状态(HDEVINFO 设备集, SP_DEVINFO_DATA& 设备信息, bool 启用)
{
	SP_PROPCHANGE_PARAMS 参数{};
	参数.ClassInstallHeader.cbSize = sizeof(SP_CLASSINSTALL_HEADER);
	参数.ClassInstallHeader.InstallFunction = DIF_PROPERTYCHANGE;
	参数.StateChange = 启用 ? DICS_ENABLE : DICS_DISABLE;
	参数.Scope = DICS_FLAG_CONFIGSPECIFIC;
	参数.HwProfile = 0;
	return SetupDiSetClassInstallParamsW(设备集, &设备信息, &参数.ClassInstallHeader, sizeof(参数)) && SetupDiCallClassInstaller(DIF_PROPERTYCHANGE, 设备集, &设备信息);
}

//轮询设备节点的即插即用状态直到达到期望的启用或禁用状态，超时毫秒为最长等待时间，超时返回false
static bool 等待设备状态(DEVINST 设备节点, bool 等待启用, unsigned 超时毫秒)
{
	const ULONGLONG 起始时刻 = GetTickCount64();
	for (;;)
	{
		ULONG 状态 = 0, 问题号 = 0;
		if (CM_Get_DevNode_Status(&状态, &问题号, 设备节点, 0) == CR_SUCCESS)
		{
			const bool 已启动 = (状态 & DN_STARTED) && !(状态 & DN_HAS_PROBLEM);
			const bool 已禁用 = (状态 & DN_HAS_PROBLEM) && 问题号 == CM_PROB_DISABLED;
			if (等待启用 ? 已启动 : 已禁用)
				return true;
		}
		if (GetTickCount64() - 起始时刻 >= 超时毫秒)
			return false;
		Sleep(1000);
	}
}

//轮询nvidia-smi直到重新枚举出该GPU的PCI地址，确认nvlddmkm完成初始化后方可做结果验证，超时返回false
static bool 等待驱动就绪(const std::wstring& 序号文本, unsigned 超时毫秒)
{
	const ULONGLONG 起始时刻 = GetTickCount64();
	for (;;)
	{
		const std::wstring 输出 = 去除首尾空白(运行命令取得输出(L"nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i " + 序号文本));
		if (输出.find(L':') != std::wstring::npos)
			return true;
		if (GetTickCount64() - 起始时刻 >= 超时毫秒)
			return false;
		Sleep(1000);
	}
}

//复位单张显卡：禁用→轮询等待禁用生效→启用→轮询等待驱动就绪→验证，触发nvlddmkm驱动重新初始化该GPU，各阶段以实际状态确认为准而非固定时长死等
static int 复位单个显卡(unsigned 索引)
{
	const std::wstring 序号文本 = std::to_wstring(索引);
	//nvidia-smi给出的PCI地址形如00000000:01:00.0（段:总线:设备.功能）
	const std::wstring 总线地址 = 去除首尾空白(运行命令取得输出(L"nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader -i " + 序号文本));
	const auto 冒号1 = 总线地址.find(L':');
	const auto 冒号2 = 冒号1 == std::wstring::npos ? std::wstring::npos : 总线地址.find(L':', 冒号1 + 1);
	const auto 小数点 = 冒号2 == std::wstring::npos ? std::wstring::npos : 总线地址.find(L'.', 冒号2 + 1);
	if (小数点 == std::wstring::npos)
	{
		std::cerr << "无法从nvidia-smi获取GPU" << 索引 << "的PCI地址（输出：" << 宽转窄(总线地址) << "），请确认序号有效且NVIDIA驱动已安装" << std::endl;
		return 1;
	}
	const unsigned 总线号 = (unsigned)wcstoul(总线地址.substr(冒号1 + 1, 冒号2 - 冒号1 - 1).c_str(), nullptr, 16);
	const unsigned 设备号 = (unsigned)wcstoul(总线地址.substr(冒号2 + 1, 小数点 - 冒号2 - 1).c_str(), nullptr, 16);
	HDEVINFO 设备集 = nullptr;
	SP_DEVINFO_DATA 设备信息{};
	std::wstring 实例标识;
	if (!查找显卡设备(总线号, 设备号, 实例标识, 设备集, 设备信息))
	{
		std::cerr << "未在PnP中找到GPU" << 索引 << "（PCI总线" << 总线号 << "、设备" << 设备号 << "）对应的NVIDIA显示设备" << std::endl;
		return 1;
	}
	DEVINST 设备节点 = 0;
	if (CM_Locate_DevNodeW(&设备节点, 实例标识.data(), 0) != CR_SUCCESS)
	{
		std::cerr << "无法取得GPU" << 索引 << "的设备节点" << std::endl;
		SetupDiDestroyDeviceInfoList(设备集);
		return 1;
	}
	std::cout << ">>> 开始复位 GPU " << 索引 << "（实例 " << 宽转窄(实例标识) << "）" << std::endl;
	std::cout << "--- 1/3 禁用设备（GPU " << 索引 << "） ---" << std::endl;
	if (!设置设备启用状态(设备集, 设备信息, false))
	{
		std::cerr << "禁用设备失败（错误码" << GetLastError() << "）" << std::endl;
		SetupDiDestroyDeviceInfoList(设备集);
		return 1;
	}
	if (!等待设备状态(设备节点, false, 20000))
	{
		std::cerr << "等待GPU" << 索引 << "禁用生效超时" << std::endl;
		SetupDiDestroyDeviceInfoList(设备集);
		return 1;
	}
	std::cout << "--- 2/3 重新启用（GPU " << 索引 << "） ---" << std::endl;
	if (!设置设备启用状态(设备集, 设备信息, true))
	{
		std::cerr << "启用设备失败（错误码" << GetLastError() << "）" << std::endl;
		SetupDiDestroyDeviceInfoList(设备集);
		return 1;
	}
	if (!等待设备状态(设备节点, true, 20000) || !等待驱动就绪(序号文本, 30000))
	{
		std::cerr << "等待GPU" << 索引 << "重新启用并就绪超时" << std::endl;
		SetupDiDestroyDeviceInfoList(设备集);
		return 1;
	}
	std::cout << "--- 3/3 复位结果验证（GPU " << 索引 << "） ---" << std::endl;
	std::cout << 宽转窄(去除首尾空白(运行命令取得输出(L"nvidia-smi --query-gpu=index,utilization.gpu,memory.used,pstate,fan.speed,temperature.gpu --format=csv,noheader -i " + 序号文本))) << std::endl;
	SetupDiDestroyDeviceInfoList(设备集);
	return 0;
}

//替换MATLAB主机名工具HostNameUtils.m中获取主机名的代码为getenv('COMPUTERNAME')，修复官方非ASCII主机名不能启动并行池的bug
static int 修改主机名工具(const std::filesystem::path& matlab根)
{
	const std::filesystem::path HNU路径 = matlab根 / L"toolbox\\parallel\\cluster\\+parallel\\+internal\\+general\\HostNameUtils.m";
	std::ifstream 输入流(HNU路径);
	std::string 行;
	if (!输入流)
	{
		std::cerr << "打不开文件：" << 宽转窄(HNU路径.wstring()) << std::endl;
		return 1;
	}
	std::ostringstream 输出缓存;
	while (std::getline(输入流, 行))
	{
		constexpr char 关键词[] = "currentlocalCanonicalHostName = ";
		const size_t 位置 = 行.find(关键词);
		if (位置 != std::string::npos)
		{
			输出缓存 << 行.substr(0, 位置 + sizeof(关键词) - 1) + "getenv('COMPUTERNAME');" << std::endl;
			break;
		}
		else
			输出缓存 << 行 << std::endl;
	}
	输出缓存 << 输入流.rdbuf();
	输入流.close();
	std::ofstream(HNU路径, std::ios::out | std::ios::trunc) << 输出缓存.str();
	return 0;
}

//复位一个或多个GPU序号（从0起，对应nvidia-smi的序号）所对应的显卡
static int 复位显卡(int 参数个数, wchar_t* 命令行参数[])
{
	if (参数个数 < 4)
	{
		std::cerr << "未指定GPU序号" << std::endl;
		return 1;
	}
	int 失败个数 = 0;
	for (int i = 3; i < 参数个数; ++i)
	{
		wchar_t* 结束位置 = nullptr;
		const unsigned long 索引 = wcstoul(命令行参数[i], &结束位置, 10);
		if (结束位置 == 命令行参数[i] || *结束位置 != L'\0')
		{
			std::cerr << "GPU序号必须是十进制整数：" << 宽转窄(命令行参数[i]) << std::endl;
			++失败个数;
			continue;
		}
		失败个数 += 复位单个显卡((unsigned)索引);
	}
	if (失败个数)
		return 1;
	return 0;
}

//提权操作.exe的入口：命令行格式为"提权操作.exe <matlabroot> <操作名> [参数…]"，操作名即ElevatedOperation的枚举成员名，参数为无符号十进制文本
int wmain(int 参数个数, wchar_t* 命令行参数[])
{
	if (参数个数 < 3)
	{
		std::cerr << "用法：提权操作.exe <matlabroot> <操作名> [参数…]" << std::endl;
		return 1;
	}
	const std::wstring 操作名 = 命令行参数[2];
	if (操作名 == L"Non_ascii_hostname_parpool_fix")
		return 修改主机名工具(命令行参数[1]);
	if (操作名 == L"Reset_Gpu")
		return 复位显卡(参数个数, 命令行参数);
	std::cerr << "未知操作：" << 宽转窄(操作名) << std::endl;
	return 1;
}