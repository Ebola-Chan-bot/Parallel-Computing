%[text] 系统级重置指定序号的GPU
%[text] 内置\`gpuDevice(\[\])\`只能让当前MATLAB会话释放GPU，不能清除该GPU被其它进程的占用或驱动异常状态。本函数在系统级对GPU进行全局重置，预计能解决大多数异常状态，但需要提升权限且会影响其它进程或其他用户。
%[text] ## 语法
%[text] ```matlabCodeExample
%[text] ParallelComputing.ResetGpu;
%[text] %重置本机上的唯一一个GPU
%[text] 
%[text] ParallelComputing.ResetGpu(GpuIndex);
%[text] %重置指定序号的GPU
%[text] ```
%[text] ## 输入参数
%[text] GpuIndex(1,:)uint8=1，GPU序号，从1开始（对应nvidia-smi的0号），所有指定的GPU将被重置。虽然默认1，但如果本机GPU不止一个，将出错；多GPU计算机必须指定GPU序号。
function ResetGpu(GpuIndex)
if~nargin&&gpuDeviceCount==1
	GpuIndex=1;
end
ParallelComputing.internal.ElevatedOperation.Reset_Gpu.Call(GpuIndex-1);
end

%[appendix]{"version":"1.0"}
%---
