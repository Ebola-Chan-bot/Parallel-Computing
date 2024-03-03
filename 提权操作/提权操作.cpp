#include<filesystem>
#include<fstream>
int wmain(int 参数个数, wchar_t* 命令行参数[])
{
	const std::filesystem::path HNU路径 = std::filesystem::path(命令行参数[1]) / L"toolbox\\parallel\\cluster\\+parallel\\+internal\\+general\\HostNameUtils.m";
	std::ifstream 输入流(HNU路径);
	std::string 行;
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