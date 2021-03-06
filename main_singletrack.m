%------------------------------------------------------------------
% Programed by: 
%   - Lucas Rath (lucasrm25@gmail.com)
%   - 
%   -

%   Control of a Race Car in a Race Track using Gaussian Process Optimal Control:
%------------------------------------------------------------------

clear all; close all; clc;


%--------------------------------------------------------------------------
% Quick Access Simulation and controller parameters
%------------------------------------------------------------------
dt = 0.2;       % simulation timestep size
tf = 600;       % simulation time
maxiter = 20;   % max NMPC iterations per time step
N = 10;         % NMPC prediction horizon

lookahead = dt*N;
fprintf('\nPrediction lookahead: %.1f [s]\n',lookahead);



%% Create True Dynamics Simulation Model
%--------------------------------------------------------------------------
%   xk+1 = fd_true(xk,uk) + Bd * ( w ),    
%
%       where: w ~ N(0,var_w)
%------------------------------------------------------------------

% define noise for true disturbance
var_w = diag([(1/3)^2 (1/3)^2 (deg2rad(3)/3)^2]);

% create true dynamics model
trueModel = MotionModelGP_SingleTrack_true( [], var_w);
% trueModel = MotionModelGP_SingleTrack_nominal(d,var_w);


%% Create Estimation Model and Nominal Model

% -------------------------------------------------------------------------
%  Create nominal model (no disturbance):  
%       xk+1 = fd_nom(xk,uk)
% -------------------------------------------------------------------------

nomModel = MotionModelGP_SingleTrack_nominal( [], [] ); 
% nomModel = MotionModelGP_SingleTrack_true( [], [] );


% -------------------------------------------------------------------------
%  Create adaptive dynamics model 
%  (unmodeled dynamics will be estimated by Gaussian Process GP)
%       xk+1 = fd_nom(xk,uk) + Bd * ( d_GP(zk) + w )
% -------------------------------------------------------------------------

% GP input dimension
gp_n = MotionModelGP_SingleTrack_nominal.nz;
% GP output dimension
gp_p = MotionModelGP_SingleTrack_nominal.nd;

% GP hyperparameters
var_f   = repmat(0.01,[gp_p,1]);    % output variance
var_n   = diag(var_w);              % measurement noise variance
M       = repmat(diag([1e0,1e0,1e0,1e0,1e0].^2),[1,1,gp_p]);     % length scale
maxsize = 300; % maximum number of points in the dictionary

% create GP object
d_GP = GP(gp_n, gp_p, var_f, var_n, M, maxsize);

% create nominal model with GP model as d(zk)
estModel = MotionModelGP_SingleTrack_nominal(@d_GP.eval, var_w);
% estModel = MotionModelGP_SingleTrack_true(@d_GP.eval, var_w);


%% Initialize Controller

% -------------------------------------------------------------------------
%       TODO: LQR CONTROLLER:
% -------------------------------------------------------------------------
% % % % [A,B] = estModel.linearize();
% % % % Ak = eye(estModel.n)+dt*A;
% % % % Bk = B*dt;
% % % % Ck=[0 1 0 0; 0 0 1 0; 0 0 0 1];
% % % % Q = 1e3*eye(estModel.n);
% % % % R = 1;
% % % % [~,~,K] = dare(Ak,Bk,Q,R);
% % % % % Prefilter
% % % % Kr = pinv(Ck/(eye(estModel.n)-Ak+Bk*K)*Bk);
% % % % % check eigenvalues
% % % % eig(Ak-Bk*K);



% -------------------------------------------------------------------------
% Create perception model (in this case is the saved track points)
% -------------------------------------------------------------------------
[trackdata, x0, th0, w] = RaceTrack.loadTrack_02();
track = RaceTrack(trackdata, x0, th0, w);
% TEST: [Xt, Yt, PSIt, Rt] = track.getTrackInfo(1000)
%       trackAnim = SingleTrackAnimation(track,mpc.N);
%       trackAnim.initGraphics()


% -------------------------------------------------------------------------
% Nonlinear Model Predictive Controller
% -------------------------------------------------------------------------

% define cost function
n  = estModel.n;
m  = estModel.m;
ne = 0;

% define cost functions
fo   = @(t,mu_x,var_x,u,e,r) costFunction(mu_x, var_x, u, track);            % e = track distance
fend = @(t,mu_x,var_x,e,r)   2 * costFunction(mu_x, var_x, zeros(m,1), track);   % end cost function

% define dynamics
 f  = @(mu_x,var_x,u) estModel.xkp1(mu_x, var_x, u, dt);
%f  = @(mu_x,var_x,u) trueModel.xkp1(mu_x, var_x, u, dt);
% define additional constraints
h  = @(x,u,e) [];
g  = @(x,u,e) [];
u_lb = [-deg2rad(20);  % >= steering angle
         -1;           % >= wheel torque gain
         5];           % >= centerline track velocity
u_ub = [deg2rad(20);   % <= steering angle
        1;             % <= wheel torque gain
        30];           % <= centerline track velocity 

% Initialize NMPC object;
mpc = NMPC(f, h, g, u_lb, u_ub, n, m, ne, fo, fend, N, dt);
mpc.tol     = 1e-2;
mpc.maxiter = maxiter;



%% Prepare simulation

% ---------------------------------------------------------------------
% Prepare simulation (initialize vectors, initial conditions and setup
% animation
% ---------------------------------------------------------------------

% define variable sizes
true_n = trueModel.n;
true_m = trueModel.m;
est_n = estModel.n;
est_m = estModel.m;

% initial state
x0 = [10;0;0; 10;0;0; 0];   % true initial state
x0(end) = track.getTrackDistance(x0(1:2)); % get initial track traveled distance

% change initial guess for mpc solver. Set initial track velocity as
% initial vehicle velocity (this improves convergence speed a lot)
mpc.uguess(end,:) = x0(4)*2;

% define simulation time
out.t = 0:dt:tf;            % time vector
kmax = length(out.t)-1;     % steps to simulate

% initialize variables to store simulation results
out.x              = [x0 NaN(true_n,kmax)];             % true states
out.xhat           = [x0 NaN(est_n, kmax)];             % state estimation
out.xnom           = [x0 NaN(est_n, kmax)];             % predicted nominal state
out.u              =     NaN(est_m, kmax);              % applied input
out.x_ref          = NaN(2,     mpc.N+1, kmax);         % optimized reference trajectory
out.mu_x_pred_opt  = NaN(mpc.n, mpc.N+1, kmax);         % mean of optimal state prediction sequence
out.var_x_pred_opt = NaN(mpc.n, mpc.n, mpc.N+1, kmax);  % variance of optimal state prediction sequence
out.u_pred_opt     = NaN(mpc.m, mpc.N,   kmax);         % open-loop optimal input prediction


% start animation
trackAnim = SingleTrackAnimation(track, out.mu_x_pred_opt, out.var_x_pred_opt, out.u_pred_opt, out.x_ref);
trackAnim.initTrackAnimation();
trackAnim.initScope();

% deactivate GP evaluation in the prediction
d_GP.isActive = false;



%% Start simulation

ki = 1;
ki = 476;
mpc.uguess = out.u_pred_opt(:,:,ki);

% lap = 0;

for k = ki:kmax
    fprintf('time: %.2f\n',out.t(k))
    
    % ---------------------------------------------------------------------
    % LQR controller
    % ---------------------------------------------------------------------
    % % out.u(:,i) = Kr*out.r(:,i) - K*out.xhat(:,i);
    
    % ---------------------------------------------------------------------
    % NPMC controller
    % ---------------------------------------------------------------------
    % calculate optimal input
    [u_opt, e_opt] = mpc.optimize(out.xhat(:,k), out.t(k), 0);
    out.u(:,k) = u_opt(:,1);
    sprintf('\nSteering angle: %d\nTorque gain: %.1f\nTrack vel: %.1f\n',rad2deg(out.u(1,k)),out.u(2,k),out.u(3,k))

    % ---------------------------------------------------------------------
    % Calculate predicted trajectory from optimal open-loop input sequence 
    % and calculate optimized reference trajectory for each prediction
    % ---------------------------------------------------------------------
    % get optimal state predictions from optimal input and current state
    out.u_pred_opt(:,:,k) = u_opt;
    [out.mu_x_pred_opt(:,:,k),out.var_x_pred_opt(:,:,:,k)] = mpc.predictStateSequence(out.xhat(:,k), zeros(estModel.n), u_opt);
    % get target track distances from predictions (last state)
    out.x_ref(:,:,k) = track.getTrackInfo(out.mu_x_pred_opt(end,:,k));
    
    % ---------------------------------------------------------------------
    % update race animation and scopes
    % ---------------------------------------------------------------------
    trackAnim.mu_x_pred_opt  = out.mu_x_pred_opt;
    trackAnim.var_x_pred_opt = out.var_x_pred_opt;
    trackAnim.u_pred_opt     = out.u_pred_opt;
    trackAnim.x_ref          = out.x_ref;
    trackAnim.updateTrackAnimation(k);
    trackAnim.updateScope(k);
    drawnow;
    
    % ---------------------------------------------------------------------
    % Simulate real model
    % ---------------------------------------------------------------------
    [mu_xkp1,var_xkp1] = trueModel.xkp1(out.x(:,k),zeros(trueModel.n),out.u(:,k),dt);
    out.x(:,k+1) = mvnrnd(mu_xkp1, var_xkp1, 1)';
    
    
    % ---------------------------------------------------------------------
    % Measure data
    % ---------------------------------------------------------------------
    out.xhat(:,k+1) = out.x(:,k+1); % perfect observer
    % get traveled distance, given vehicle coordinates
    out.xhat(end,k+1) = track.getTrackDistance(out.xhat([1,2],k+1));
    
    
    % ---------------------------------------------------------------------
    % Lap timer
    % ---------------------------------------------------------------------
    [laptimes, idxnewlaps] = getLapTimes(out.xhat(end,:),dt);
    if any(k==idxnewlaps)
        dispLapTimes(laptimes);
    end
    % lap = numel(laptimes)+1;
    
    % ---------------------------------------------------------------------
    % Safety - Stop simulation in case vehicle is completely unstable
    % ---------------------------------------------------------------------
    V_vx = out.xhat(4,k+1);
    V_vy = out.xhat(5,k+1);
    beta = atan2(V_vy,V_vx);
    if V_vx < 0
        error('Vehicle is driving backwards... aborting');
    end
    if abs(rad2deg(beta)) > 80
        error('Vehicle has a huge sideslip angle... aborting')
    end    
    
    % ---------------------------------------------------------------------
    % calculate nominal model
    % ---------------------------------------------------------------------
    out.xnom(:,k+1) = nomModel.xkp1(out.xhat(:,k),zeros(nomModel.n),out.u(:,k),dt);
    
    fprintf('Error:\n')
    disp(out.xhat(:,k+1) - mu_xkp1) % out.xnom(:,k+1)) 
    
    % ---------------------------------------------------------------------
    % Add data to GP model
    % ---------------------------------------------------------------------
    if mod(k-1,1)==0
        % calculate disturbance (error between measured and nominal)
        d_est = estModel.Bd \ (out.xhat(:,k+1) - out.xnom(:,k+1));
        % select subset of coordinates that will be used in GP prediction
        zhat = [ estModel.Bz_x * out.xhat(:,k); estModel.Bz_u * out.u(:,k) ];
        % add data point to the GP dictionary
        d_GP.add(zhat,d_est');
        d_GP.updateModel();
    end
    
%     if d_GP.N > 3 && out.t(k) > 2
%         d_GP.isActive = true;
%     end
    
    % check if these values are the same:
    % d_est == mu_d(zhat) == ([mud,~]=trueModel.d(zhat); mud*dt)
   
end


%% Display Lap times

[laptimes, idxnewlaps] = getLapTimes(out.xhat(end,:),dt);
dispLapTimes(laptimes)


%%

for k=1:1100
    % calculate disturbance (error between measured and nominal)
    d_est = estModel.Bd \ (out.xhat(:,k+1) - out.xnom(:,k+1));
    % select subset of coordinates that will be used in GP prediction
    zhat = [ estModel.Bz_x * out.xhat(:,k); estModel.Bz_u * out.u(:,k) ];
    % add data point to the GP dictionary
    d_GP.add(zhat,d_est');
end
d_GP.updateModel();

%% Analyse learning [IN PROGRESS]

% ---------------------------------------------------------------------
% Check in which region of the tyre dynamics we are working in the
% ---------------------------------------------------------------------

% % % % simulation
% % % 
% % % trueModel.testTyres
% % % 
% % % l_f  = 0.9;
% % % l_r  = 1.5;
% % % V_vx = out.xhat(4,:);
% % % V_vy = out.xhat(5,:);
% % % psi_dot = out.xhat(6,:);
% % % delta = out.u(1,:);
% % % a_r = atan2(V_vy-l_r.*psi_dot,V_vx);
% % % a_f = atan2(V_vy+l_f.*psi_dot,V_vx) - [delta 0];
% % % 
% % % figure('Color','w'); hold on; grid on;
% % % plot(rad2deg(a_r))
% % % plot(rad2deg(a_f))
% % % ylabel('slip angle')
% % % xlabel('time step')


% ---------------------------------------------------------------------
% Check how the GP reduces the prediction error
% ---------------------------------------------------------------------

% prediction error without GP
predErrorNOgp = estModel.Bd\(out.xhat - out.xnom);

% prediction error with trained GP
d_GP.isActive = true;
zhat = [ estModel.Bz_x * out.xhat; estModel.Bz_u * [out.u,zeros(3,1)] ];
dgp = d_GP.eval(zhat);
predErrorWITHgp = estModel.Bd\(out.xhat - (out.xnom + estModel.Bd*dgp) );


disp('Prediction mean squared error without GP:')
disp( mean(predErrorNOgp(:,all(~isnan(predErrorNOgp))).^2 ,2) )
disp('Prediction mean squared error with trained GP:')
disp( mean(predErrorWITHgp(:,all(~isnan(predErrorWITHgp))).^2 ,2) )



% Visualize error
figure('Color','w'); hold on; grid on;
subplot(1,2,1)
plot( predErrorNOgp' )
title('Prediction error - without GP')
subplot(1,2,2)
hist(predErrorNOgp')

figure('Color','w'); hold on; grid on;
subplot(1,2,1)
plot( predErrorWITHgp' )
title('Prediction error - with GP')
subplot(1,2,2)
hist(predErrorWITHgp')


%% Show animation
close all;

% start animation
trackAnim = SingleTrackAnimation(track,out.mu_x_pred_opt,out.var_x_pred_opt, out.u_pred_opt,out.x_ref);
trackAnim.initTrackAnimation();
% trackAnim.initScope();
for k=1:kmax
    if ~ trackAnim.updateTrackAnimation(k)
        break;
    end
    % trackAnim.updateScope(k);
    pause(0.15);
    drawnow;
end

%% Record video

FrameRate = 7;
videoName = fullfile('simresults',sprintf('trackAnimVideo-%s',date));
videoFormat = 'Motion JPEG AVI';
trackAnim.recordvideo(videoName, videoFormat, FrameRate);


%% Help functions

function cost = costFunction(mu_x, var_x, u, track)

    % Track oriented penalization
    q_l   = 50;     % penalization of lag error
    q_c   = 20;     % penalization of contouring error
    q_o   = 5;      % penalization for orientation error
    q_d   = -3;     % reward high track centerline velocites
    q_r   = 100;    % penalization when vehicle is outside track
    
    % state and input penalization
    q_v      = -0;  % reward high absolute velocities
    q_st     =  0;  % penalization of steering
    q_br     =  0;  % penalization of breaking
    q_psidot =  8;  % penalize high yaw rates
    q_acc    = -0;  % reward for accelerating

    % label inputs and outputs
    I_x        = mu_x(1);  % x position in global coordinates
    I_y        = mu_x(2);  % y position in global coordinates
    psi        = mu_x(3);  % yaw
    V_vx       = mu_x(4);  % x velocity in vehicle coordinates
    V_vy       = mu_x(5);  % x velocity in vehicle coordinates
    psidot     = mu_x(6);
    track_dist = mu_x(7);  % track centerline distance
    delta      = u(1);     % steering angle rad2deg(delta)
    T          = u(2);     % torque gain (1=max.acc, -1=max.braking)
    track_vel  = u(3);     % track centerline velocity
    

    % ---------------------------------------------------------------------
    % cost of contour, lag and orientation error
    % ---------------------------------------------------------------------

    % get lag, contour, offroad and orientation error of the vehicle w.r.t.
    % a point in the trajectory that is 'track_dist' far away from the 
    % origin along the track centerline (traveled distance)
    [lag_error, countour_error, offroad_error, orientation_error] = ...
        track.getVehicleDeviation([I_x;I_y], psi, track_dist);
    
    cost_contour     = q_c * countour_error^2;
    cost_lag         = q_l * lag_error^2;
    cost_orientation = q_o * orientation_error^2;
    
    % ---------------------------------------------------------------------
    % cost for being outside track
    % ---------------------------------------------------------------------
    % % apply smooth barrier function (we want: offroad_error < 0). 
    % alpha = 40; % smoothing factor... the smaller the smoother
    % offroad_error = (1+exp(-alpha*(offroad_error+0.05))).^-1;
    gamma = 1000;
    lambda = -0.1;
    offroad_error = 5*(sqrt((4+gamma*(lambda-offroad_error).^2)/gamma) - (lambda-offroad_error));

    % % CHECK SMOOTH TRANSITION
    % x = -0.5:0.01:0.5
    % % Smooth >=0 boolean function
    % alpha = 40; % the larger the sharper the clip function
    % y = (1+exp(-alpha*(x+0.05))).^-1 + exp(x);
    % gamma = 10000;
    % lambda = -0.2;
    % y = 0.5*(sqrt((4+gamma*(lambda-x).^2)/gamma) - (lambda-x));
    % figure; hold on; grid on;
    % plot(x,y)
    cost_outside = q_r * offroad_error^2;
    
    % ---------------------------------------------------------------------
    % reward high velocities
    % ---------------------------------------------------------------------
    cost_vel = q_v * norm([V_vx; V_vy]);
    
    % ---------------------------------------------------------------------
    % penalize high yaw rates
    % ---------------------------------------------------------------------
    cost_psidot = q_psidot * psidot^2;
    
    % ---------------------------------------------------------------------
    % reward high track velocities
    % ---------------------------------------------------------------------
    cost_dist = q_d * track_vel;
    
    % ---------------------------------------------------------------------
    % penalize acceleration, braking and steering
    % ---------------------------------------------------------------------
    cost_inputs = (T>0)*q_acc*T^2 + (T<0)*q_br*T^2 + q_st*(delta)^2 ;
    
    % ---------------------------------------------------------------------
    % Calculate final cost
    % ---------------------------------------------------------------------
    cost = cost_contour + ...
           cost_lag + ...
           cost_orientation + ...
           cost_dist + ...
           cost_outside + ...
           cost_inputs + ...
           cost_vel + ...
           cost_psidot;
end


function [laptimes, idxnewlaps] = getLapTimes( trackDist, dt)
    % calc lap times
    idxnewlaps = find( conv(trackDist, [1 -1]) < -10 );
    laptimes = conv(idxnewlaps, [1,-1], 'valid') * dt;
end

function dispLapTimes(laptimes)
    % calc best lap time
    [bestlaptime,idxbestlap] = min(laptimes);

    fprintf('\n--------------- LAP RECORD -------------------\n');
    fprintf('------ (Best Lap: %.2d    laptime: %4.2f) ------\n\n',idxbestlap,bestlaptime);
    for i=1:numel(laptimes)
        if i==idxbestlap
            fprintf(2,'  (best lap)->  ')
        else
            fprintf('\t\t');
        end
            fprintf('Lap %.2d    laptime: %4.2fs',i,laptimes(i));
            fprintf(2,'   (+%.3fs)\n',laptimes(i)-bestlaptime)

    end
    fprintf('--------------- LAP RECORD -------------------\n');

    % figure('Color','w','Position',[441 389 736 221]); hold on; grid on;
    % plot(laptimes,'-o')
    % xlabel('Lap')
    % ylabel('Lap time [s]')
end