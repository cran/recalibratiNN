## ----include = FALSE----------------------------------------------------------
knitr::opts_chunk$set(
  collapse = TRUE,
  message = FALSE,
  comment = "#>"
)

## ----setup--------------------------------------------------------------------
library(recalibratiNN)

## ----echo = F-----------------------------------------------------------------

library(glue)
library(RANN)
library(dplyr)
library(purrr)
library(tidyr)
library(ggplot2)


## -----------------------------------------------------------------------------
set.seed(42)   # The Answer to the Ultimate Question of Life, The Universe, and Everything

n <- 10000

x <- cbind(x1 = runif(n, -3, 3),
           x2 = runif(n, -5, 5))

mu_fun <- function(x) {
  abs(x[,1]^3 - 50*sin(x[,2]) + 30)}

mu <- mu_fun(x)
y <- rnorm(n, 
           mean = mu, 
           sd=20*(abs(x[,2]/(x[,1]+ 10))))

split1 <- 0.6
split2 <- 0.8

x_train <- x[1:(split1*n),]
y_train <- y[1:(split1*n)]

x_cal  <- x[(split1*n+1):(n*split2),]
y_cal  <- y[(split1*n+1):(n*split2)]

x_test <- x[(split2*n+1):n,]
y_test  <- y[(split2*n+1):n]


## ----eval=F-------------------------------------------------------------------
# model_nn <- keras_model_sequential()
# 
# model_nn |>
#   layer_dense(input_shape=2,
#               units=800,
#               use_bias=T,
#               activation = "relu",
#               kernel_initializer="random_normal",
#               bias_initializer = "zeros") %>%
#   layer_dropout(rate = 0.1) %>%
#   layer_dense(units=800,
#               use_bias=T,
#               activation = "relu",
#               kernel_initializer="random_normal",
#               bias_initializer = "zeros") |>
#   layer_dropout(rate = 0.1) |>
#   layer_dense(units=800,
#               use_bias=T,
#               activation = "relu",
#               kernel_initializer="random_normal",
#               bias_initializer = "zeros") |>
#    layer_batch_normalization() |>
#   layer_dense(units = 1,
#               activation = "linear",
#               kernel_initializer = "zeros",
#               bias_initializer = "zeros")
# 
# model_nn |>
#   compile(optimizer=optimizer_adam( ),
#     loss = "mse")
# 
# model_nn |>
#   fit(x = x_train,
#       y = y_train,
#       validation_data = list(x_cal, y_cal),
#       callbacks = callback_early_stopping(
#         monitor = "val_loss",
#         patience = 20,
#         restore_best_weights = T),
#       batch_size = 128,
#       epochs = 1000)
# 
# 
# y_hat_cal <- predict(model_nn, x_cal)
# y_hat_test <- predict(model_nn, x_test)

## ----echo = F-----------------------------------------------------------------
# carregar os vetores .rds

file_path1 <- system.file("extdata", "mse_cal.rds", package = "recalibratiNN")
MSE_cal <- readRDS(file_path1)|> as.numeric()

file_path2 <- system.file("extdata", "y_hat_cal.rds", package = "recalibratiNN")
y_hat_cal <- readRDS(file_path2)|> as.numeric()

file_path3 <- system.file("extdata", "y_hat_test.rds", package = "recalibratiNN")
y_hat_test <- readRDS(file_path3)|> as.numeric()


## -----------------------------------------------------------------------------
## Global calibrations
pit <- PIT_global(ycal = y_cal, 
                  yhat = y_hat_cal, 
                  mse = MSE_cal)

gg_PIT_global(pit)

## -----------------------------------------------------------------------------
gg_CD_global(pit, 
             ycal = y_cal,      # true response of calibration set
             yhat = y_hat_cal,  # predictions of calibration set
             mse = MSE_cal)    # mse from training on calibration set

## -----------------------------------------------------------------------------
pit_local <- PIT_local(xcal = x_cal,
                       ycal = y_cal, 
                       yhat = y_hat_cal, 
                       mse = MSE_cal
                       )

gg_PIT_local(pit_local)

## -----------------------------------------------------------------------------
gg_CD_local(pit_local, mse = MSE_cal)

## -----------------------------------------------------------------------------
coverage_model <- tibble(
  x1cal = x_test[,1], 
  x2cal = x_test[,2],
  y_real = y_test, 
  y_hat = y_hat_test) |> 
mutate(lwr = qnorm(0.05, y_hat, sqrt(MSE_cal)),
       upr = qnorm(0.95, y_hat, sqrt(MSE_cal)),
       CI = ifelse(y_real <= upr & y_real >= lwr, 
                       "in",  "out" ),
       coverage = round(mean(CI == "in")*100,1) 
)

coverage_model |> 
  arrange(CI) |>   
  ggplot() +
  geom_point(aes(x1cal, 
                 x2cal, 
                 color = CI),
             alpha = 0.9,
             size = 2)+
   labs(x="x1" , y="x2", 
        title = glue("Original coverage: {coverage_model$coverage[1]} %"))+
  scale_color_manual("Confidence Interval",
                     values = c("in" = "aquamarine3", 
                                "out" = "steelblue4"))+
  theme_classic()

## -----------------------------------------------------------------------------
recalibrated <- 
  recalibrate(
    yhat_new = y_hat_test, # predictions of test set
    space_cal = x_cal,     # covariates of calibration set
    pit_values = pit,      # global pit values calculated earlier.
    space_new = x_test,    # covariates of test set
    mse = MSE_cal,         # MSE from calibration set
    type = "local",        # type of calibration
    p_neighbours = 0.08)   # proportion of calibration to use as nearest neighbors

y_hat_rec <- recalibrated$y_samples_calibrated_wt

## -----------------------------------------------------------------------------

n_clusters <- 6 
n_neighbours <- length(y_hat_test)*0.08


# calculating centroids
cluster_means_cal <- kmeans(x_test, n_clusters)$centers

cluster_means_cal <- cluster_means_cal[order(cluster_means_cal[,1]),]

  
# finding neighbours
knn_cal <- nn2(x_test, 
               cluster_means_cal, 
               k = n_neighbours)$nn.idx


# geting corresponding ys (real and estimated)
y_real_local <- map(1:nrow(knn_cal),  ~y_test[knn_cal[.,]])

y_hat_local <- map(1:nrow(knn_cal),  ~y_hat_rec[knn_cal[.,],])


# calculate pit_local
pits <- matrix(NA, 
               nrow = 6, 
               ncol = n_neighbours)

for (i in 1:n_clusters) {
    pits[i,] <- map_dbl(1:n_neighbours, ~{
      mean(y_hat_local[[i]][.,] <= y_hat_local[[i]][.])
    })
}

as.data.frame(t(pits)) |> 
  pivot_longer(everything()) |> 
  group_by(name) |>
  mutate(p_value =ks.test(value,
                          "punif")$p.value,
         name = gsub("V", "part_", name)) |> 
  ggplot()+
  geom_density(aes(value,
                   color = name,
                   fill = name),
               alpha = 0.5,
               bounds = c(0, 1))+
  geom_hline(yintercept = 1, 
             linetype="dashed")+
  scale_color_brewer(palette = "Set2")+
  scale_fill_brewer(palette = "Set2")+
  theme_classic()+
  geom_text(aes(x = 0.5, 
                y = 0.5,
                label = glue("p-value: {round(p_value, 3)}")),
            color = "black",
            size = 3)+
  theme(legend.position = "none")+
  labs(title = "After Local Calibration",
       subtitle = "It looks so much better!!",
       x = "PIT-values",
       y = "Density")+
  facet_wrap(~name, scales = "free_y")

## -----------------------------------------------------------------------------
 coverage_rec <- map_dfr( 1:nrow(x_test), ~ {
  quantile(y_hat_rec[.,]
           ,c(0.05, 0.95))}) |> 
  mutate(
    x1 = x_test[,1],
    x2 = x_test[,2],
    ytest = y_test,
    CI = ifelse(ytest <= `95%`& ytest >= `5%`, 
                "in", "out"),
    coverage = round(mean(CI == "in")*100,1)) |> 
  arrange(CI)

 coverage_rec |> 
   ggplot() +
   geom_point(aes(x1, x2, color = CI),
              alpha = 0.9,
              size = 2)+
   labs(x="x1" , y="x2", 
        title = glue("Recalibrated coverage: {coverage_rec$coverage[1]} %"))+
  scale_color_manual("Confidence Interval",
                     values = c("in" = "aquamarine3", 
                                "out" = "steelblue4"))+
  theme_classic()

## ----include = F--------------------------------------------------------------
data.frame(
  real = mu_fun(x_test),
  desc = y_hat_test,
  recal = recalibrated$y_hat_calibrated
) |> 
  pivot_longer(-real) |> 
  arrange(name) |> 
  ggplot()+
  geom_point(aes( x = value,
                  y = real,
                  color = name),
             alpha = 0.7)+ 
  scale_color_manual("", values = c( "#003366","#80b298"),
                     labels = c("Predicted", "Recalibrated"))+
  geom_abline(color="red", linetype="dashed")+
  labs(x="Estimated Mean", y="True Mean")+
  theme_bw(base_size = 14) +
  theme(axis.title.y=element_text(colour="black"),
        axis.title.x = element_text(colour="black"),
        axis.text = element_text(colour = "black"),
        legend.position = c(0.8, 0.2),
        panel.border = element_blank(),
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(),
        axis.line = element_line(colour = "black"),
        plot.margin = margin(0, 0, 0, 0.2, "cm"))


