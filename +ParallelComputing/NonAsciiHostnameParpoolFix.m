%[text] 替官方修复含有非ASCII字符的主机名的主机不能启动并行池的问题
%[text] MATLAB自古以来就存在的bug，如果主机名含有非ASCII字符，例如中文，就不能启动并行池（线程并行池除外）。此bug历经多个大版本始终没有修复。本函数只需运行一次即可彻底修复此问题。但是，修复后必须重启MATLAB才能生效。
%[text] ## 语法
%[text] ```matlabCodeExample
%[text] ParallelComputing.NonAsciiHostnameParpoolFix
%[text] %修复问题，但不重启MATLAB
%[text] 
%[text] ParallelComputing.NonAsciiHostnameParpoolFix(true)
%[text] %修复问题并立即重启MATLAB
%[text] ```
%[text] ## 输入参数
%[text] RestartMatlab(1,1)logical=false，修复后是否立即重启MATLAB。重启依赖当前环境变量Path中包含matlab可执行文件所在路径，否则只会关闭当前会话，而不会启动新的。
function NonAsciiHostnameParpoolFix(RestartMatlab)
ParallelComputing.internal.ElevatedOperation.Non_ascii_hostname_parpool_fix.Call;
if nargin&&RestartMatlab
	!matlab &
	exit
end

%[appendix]{"version":"1.0"}
%---
